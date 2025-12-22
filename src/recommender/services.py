import json
import logging
import math
import os
import time
import uuid
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger(__name__)

EMBEDDING_VERSION = "v1"
DEFAULT_TEMPO_MIN = 50.0
DEFAULT_TEMPO_MAX = 200.0
DEFAULT_QUEUE_SIZE = 10
DEFAULT_INDEX_TTL_SECONDS = 300.0

PROFILE_TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "")
ITEM_VECTORS_PATH = os.environ.get("ITEM_VECTORS_PATH", "")
ITEM_VECTORS_S3_BUCKET = os.environ.get("ITEM_VECTORS_S3_BUCKET", "")
ITEM_VECTORS_S3_KEY = os.environ.get("ITEM_VECTORS_S3_KEY", "")
ITEM_INDEX_TTL_SECONDS = os.environ.get("ITEM_INDEX_TTL_SECONDS", "")

_dynamodb_resource = boto3.resource("dynamodb")
_profile_table = None
_item_index_cache: dict[str, Any] = {"loaded_at": 0.0, "payload": None, "source": ""}


def log_structured(level: str, message: str, **fields: Any) -> None:
    """Log a structured JSON message with consistent fields.

    Args:
        level: The log level name (info, warning, error).
        message: The human-readable log message.
        **fields: Additional fields to include in the log payload.

    Returns:
        None.
    """
    payload = {"message": message, **fields}
    serialized = json.dumps(payload, ensure_ascii=True, default=str)
    getattr(logger, level)(serialized)


def safe_float(value: Any, default: float = 0.0) -> float:
    """Safely cast a value to float with a fallback default.

    Args:
        value: The input value to convert.
        default: The fallback value if conversion fails.

    Returns:
        The converted float or the default value.
    """
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def normalize_genre_label(label: str) -> str:
    """Normalize a genre label for consistent dictionary keys.

    Args:
        label: The raw genre label.

    Returns:
        The normalized genre label.
    """
    return label.strip().replace(" ", "_")


def parse_genre_vocab() -> list[str]:
    """Parse the genre vocabulary from the environment.

    Returns:
        The list of normalized genre labels.
    """
    raw_vocab = os.environ.get("RECOMMENDER_GENRE_VOCAB", "")
    if not raw_vocab:
        return []
    return [normalize_genre_label(value) for value in raw_vocab.split(",") if value.strip()]


def get_tempo_bounds() -> tuple[float, float]:
    """Load tempo normalization bounds from the environment.

    Returns:
        A tuple with (min_tempo, max_tempo).
    """
    min_value = safe_float(os.environ.get("RECOMMENDER_TEMPO_MIN"), DEFAULT_TEMPO_MIN)
    max_value = safe_float(os.environ.get("RECOMMENDER_TEMPO_MAX"), DEFAULT_TEMPO_MAX)
    if max_value <= min_value:
        return DEFAULT_TEMPO_MIN, DEFAULT_TEMPO_MAX
    return min_value, max_value


def normalize_min_max(value: float, min_value: float, max_value: float) -> float:
    """Normalize a value with min-max scaling and clamp to [0, 1].

    Args:
        value: The numeric value to normalize.
        min_value: The minimum bound for normalization.
        max_value: The maximum bound for normalization.

    Returns:
        The normalized value between 0 and 1.
    """
    if max_value <= min_value:
        return 0.0
    normalized = (value - min_value) / (max_value - min_value)
    return max(0.0, min(1.0, normalized))


def build_user_embedding(profile: dict, genre_vocab: list[str], tempo_min: float, tempo_max: float) -> tuple[list[float], dict]:
    """Build a user embedding vector from the user profile.

    Args:
        profile: The user profile document from DynamoDB.
        genre_vocab: The normalized genre vocabulary used by the item vectors.
        tempo_min: Minimum tempo used for normalization.
        tempo_max: Maximum tempo used for normalization.

    Returns:
        A tuple containing the embedding vector and its metadata.
    """
    audio_profile = profile.get("audio_profile", {}) or {}
    audio_vector = [
        safe_float(audio_profile.get("avg_danceability")),
        safe_float(audio_profile.get("avg_energy")),
        safe_float(audio_profile.get("avg_valence")),
        safe_float(audio_profile.get("avg_acousticness")),
        normalize_min_max(safe_float(audio_profile.get("avg_tempo")), tempo_min, tempo_max),
    ]

    genre_affinity = profile.get("genre_affinity", {}) or {}
    total_genre_count = sum(safe_float(value) for value in genre_affinity.values())
    genre_vector = []
    for genre in genre_vocab:
        count = safe_float(genre_affinity.get(genre))
        genre_vector.append(count / total_genre_count if total_genre_count > 0 else 0.0)

    feature_order = [
        "danceability",
        "energy",
        "valence",
        "acousticness",
        "tempo_normalized",
        *[f"genre_{genre}" for genre in genre_vocab],
    ]
    metadata = {
        "embedding_version": EMBEDDING_VERSION,
        "feature_order": feature_order,
        "genre_vocab": genre_vocab,
        "tempo_min": tempo_min,
        "tempo_max": tempo_max,
    }
    return audio_vector + genre_vector, metadata


def get_profile_table():
    """Return the DynamoDB table for user profiles.

    Returns:
        The DynamoDB Table resource.

    Raises:
        ValueError: If the DynamoDB table name is not configured.
    """
    global _profile_table
    if not PROFILE_TABLE_NAME:
        raise ValueError("Missing DYNAMODB_TABLE environment variable.")
    if _profile_table is None:
        _profile_table = _dynamodb_resource.Table(PROFILE_TABLE_NAME)
    return _profile_table


def fetch_user_profile(user_id: str, request_id: str | None = None) -> dict | None:
    """Fetch the user profile from DynamoDB.

    Args:
        user_id: The user identifier to fetch.
        request_id: The request identifier for correlation.

    Returns:
        The user profile dict or None when not found or on error.
    """
    try:
        table = get_profile_table()
        response = table.get_item(Key={"user_id": user_id})
    except (ClientError, BotoCoreError, ValueError) as exc:
        log_structured(
            "error",
            "Failed to fetch user profile from DynamoDB.",
            request_id=request_id,
            user_id=user_id,
            error=str(exc),
        )
        return None
    return response.get("Item")


def update_recommendation_queue(
    user_id: str,
    queue: list[str],
    embedding_version: str,
    embedding_updated_at: int,
    request_id: str | None = None,
) -> None:
    """Update the recommendation queue metadata in DynamoDB.

    Args:
        user_id: The user identifier to update.
        queue: The list of recommended track identifiers.
        embedding_version: The embedding version used to create the queue.
        embedding_updated_at: The profile embedding updated timestamp.
        request_id: The request identifier for correlation.

    Returns:
        None.
    """
    try:
        table = get_profile_table()
        table.update_item(
            Key={"user_id": user_id},
            UpdateExpression=(
                "SET recommendation_queue = :queue, "
                "queue_updated_at = :queue_ts, "
                "queue_embedding_version = :queue_version, "
                "queue_embedding_ts = :embed_ts"
            ),
            ExpressionAttributeValues={
                ":queue": queue,
                ":queue_ts": int(time.time()),
                ":queue_version": embedding_version,
                ":embed_ts": embedding_updated_at,
            },
        )
    except (ClientError, BotoCoreError, ValueError) as exc:
        log_structured(
            "error",
            "Failed to update recommendation queue in DynamoDB.",
            request_id=request_id,
            user_id=user_id,
            error=str(exc),
        )


def load_item_index(request_id: str | None = None) -> dict | None:
    """Load the item vector index from disk or S3.

    Args:
        request_id: The request identifier for correlation.

    Returns:
        The loaded item index payload or None when unavailable.
    """
    ttl_seconds = safe_float(ITEM_INDEX_TTL_SECONDS, DEFAULT_INDEX_TTL_SECONDS)
    cached_payload = _item_index_cache.get("payload")
    if cached_payload and time.time() - _item_index_cache.get("loaded_at", 0.0) < ttl_seconds:
        return cached_payload

    payload = None
    source = ""
    if ITEM_VECTORS_PATH:
        source = ITEM_VECTORS_PATH
        try:
            with open(ITEM_VECTORS_PATH, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            log_structured(
                "error",
                "Failed to load item vectors from disk.",
                request_id=request_id,
                path=ITEM_VECTORS_PATH,
                error=str(exc),
            )
            payload = None
    elif ITEM_VECTORS_S3_BUCKET and ITEM_VECTORS_S3_KEY:
        source = f"s3://{ITEM_VECTORS_S3_BUCKET}/{ITEM_VECTORS_S3_KEY}"
        try:
            s3_client = boto3.client("s3")
            response = s3_client.get_object(
                Bucket=ITEM_VECTORS_S3_BUCKET,
                Key=ITEM_VECTORS_S3_KEY,
            )
            payload = json.loads(response["Body"].read().decode("utf-8"))
        except (ClientError, BotoCoreError, json.JSONDecodeError, KeyError, UnicodeDecodeError) as exc:
            log_structured(
                "error",
                "Failed to load item vectors from S3.",
                request_id=request_id,
                bucket=ITEM_VECTORS_S3_BUCKET,
                key=ITEM_VECTORS_S3_KEY,
                error=str(exc),
            )
            payload = None
    else:
        log_structured(
            "warning",
            "Item vector source is not configured.",
            request_id=request_id,
        )
        return None

    if payload is None:
        return None

    normalized_payload = normalize_item_index_payload(payload, request_id=request_id, source=source)
    if normalized_payload is None:
        return None

    _item_index_cache.update({
        "loaded_at": time.time(),
        "payload": normalized_payload,
        "source": source,
    })
    return normalized_payload


def normalize_item_index_payload(payload: Any, request_id: str | None, source: str) -> dict | None:
    """Normalize raw item vector payloads into a consistent structure.

    Args:
        payload: The raw payload loaded from disk or S3.
        request_id: The request identifier for correlation.
        source: The source path or URI for logging.

    Returns:
        A normalized payload dict or None if invalid.
    """
    if isinstance(payload, dict):
        items = payload.get("items", [])
        feature_order = payload.get("feature_order", [])
    elif isinstance(payload, list):
        items = payload
        feature_order = []
    else:
        log_structured(
            "error",
            "Unsupported item index payload format.",
            request_id=request_id,
            source=source,
        )
        return None

    if not isinstance(items, list):
        log_structured(
            "error",
            "Item index payload is missing a list of items.",
            request_id=request_id,
            source=source,
        )
        return None

    normalized_items = []
    for item in items:
        if not isinstance(item, dict):
            continue
        item_id = item.get("item_id") or item.get("track_id")
        vector = item.get("vector")
        if not item_id or not isinstance(vector, list):
            continue
        normalized_items.append({
            "item_id": item_id,
            "vector": [safe_float(value) for value in vector],
            "artist_id": item.get("artist_id"),
        })

    return {"items": normalized_items, "feature_order": feature_order}


def cosine_similarity(vector_a: list[float], vector_b: list[float]) -> float:
    """Compute cosine similarity between two vectors.

    Args:
        vector_a: The first vector.
        vector_b: The second vector.

    Returns:
        The cosine similarity score.
    """
    if len(vector_a) != len(vector_b):
        return 0.0
    dot_product = sum(a * b for a, b in zip(vector_a, vector_b))
    norm_a = math.sqrt(sum(a * a for a in vector_a))
    norm_b = math.sqrt(sum(b * b for b in vector_b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot_product / (norm_a * norm_b)


def get_recent_track_ids(profile: dict) -> set[str]:
    """Extract recent track identifiers from the user profile.

    Args:
        profile: The user profile document from DynamoDB.

    Returns:
        A set of recent track identifiers.
    """
    recent_history = profile.get("recent_history", []) or []
    recent_track_ids = set()
    for entry in recent_history:
        if isinstance(entry, dict):
            track_id = entry.get("track_id")
            if track_id:
                recent_track_ids.add(track_id)
    return recent_track_ids


def normalize_queue(queue: Any) -> list[str]:
    """Normalize a stored queue into a list of track identifiers.

    Args:
        queue: The stored queue data.

    Returns:
        A list of track identifiers.
    """
    if not isinstance(queue, list):
        return []
    normalized = []
    for entry in queue:
        if isinstance(entry, dict):
            track_id = entry.get("track_id")
            if track_id:
                normalized.append(track_id)
        elif isinstance(entry, str):
            normalized.append(entry)
    return normalized


def rank_items(
    user_vector: list[float],
    items: list[dict],
    exclude_ids: set[str],
    limit: int,
) -> list[str]:
    """Rank items by similarity to the user vector.

    Args:
        user_vector: The user embedding vector.
        items: The list of item vectors.
        exclude_ids: Track identifiers to exclude from ranking.
        limit: The maximum number of recommendations to return.

    Returns:
        A list of track identifiers ranked by similarity.
    """
    scored_items: list[tuple[float, str]] = []
    for item in items:
        item_id = item.get("item_id")
        if not item_id or item_id in exclude_ids:
            continue
        vector = item.get("vector")
        if not isinstance(vector, list):
            continue
        if len(vector) != len(user_vector):
            continue
        score = cosine_similarity(user_vector, vector)
        scored_items.append((score, item_id))

    scored_items.sort(key=lambda entry: entry[0], reverse=True)
    return [item_id for score, item_id in scored_items[:limit]]


def get_recommendation_queue(user_id: str, queue_size: int = DEFAULT_QUEUE_SIZE) -> list[str]:
    """Return a recommendation queue for the given user.

    Args:
        user_id: The user identifier to generate recommendations for.
        queue_size: The maximum queue size.

    Returns:
        The list of recommended track identifiers.
    """
    request_id = uuid.uuid4().hex
    profile = fetch_user_profile(user_id, request_id=request_id)
    if not profile:
        return []

    existing_queue = normalize_queue(profile.get("recommendation_queue", []))
    embedding_version = profile.get("embedding_version", EMBEDDING_VERSION)
    embedding_updated_at = int(safe_float(profile.get("embedding_updated_at"), 0))
    queue_embedding_version = profile.get("queue_embedding_version", "")
    queue_embedding_ts = int(safe_float(profile.get("queue_embedding_ts"), 0))

    queue_is_fresh = (
        queue_embedding_version == embedding_version
        and queue_embedding_ts >= embedding_updated_at
        and len(existing_queue) >= queue_size
    )
    if queue_is_fresh:
        log_structured(
            "info",
            "Returning cached recommendation queue.",
            request_id=request_id,
            user_id=user_id,
            queue_size=len(existing_queue),
        )
        return existing_queue[:queue_size]

    if queue_embedding_version != embedding_version or queue_embedding_ts < embedding_updated_at:
        existing_queue = []

    user_embedding = profile.get("user_embedding")
    if isinstance(user_embedding, list):
        user_vector = [safe_float(value) for value in user_embedding]
    else:
        genre_vocab = parse_genre_vocab()
        tempo_min, tempo_max = get_tempo_bounds()
        user_vector, embedding_meta = build_user_embedding(profile, genre_vocab, tempo_min, tempo_max)
        log_structured(
            "warning",
            "User embedding missing in profile; computed on the fly.",
            request_id=request_id,
            user_id=user_id,
            embedding_version=embedding_meta.get("embedding_version"),
        )

    item_index = load_item_index(request_id=request_id)
    if not item_index:
        log_structured(
            "warning",
            "Item index is not available; returning existing queue.",
            request_id=request_id,
            user_id=user_id,
        )
        return existing_queue[:queue_size]

    items = item_index.get("items", [])
    if not items:
        log_structured(
            "warning",
            "Item index is empty; returning existing queue.",
            request_id=request_id,
            user_id=user_id,
        )
        return existing_queue[:queue_size]

    exclude_ids = get_recent_track_ids(profile)
    exclude_ids.update(existing_queue)

    candidates = rank_items(
        user_vector=user_vector,
        items=items,
        exclude_ids=exclude_ids,
        limit=max(queue_size * 2, queue_size),
    )
    new_queue = existing_queue + candidates
    new_queue = new_queue[:queue_size]

    update_recommendation_queue(
        user_id=user_id,
        queue=new_queue,
        embedding_version=embedding_version,
        embedding_updated_at=embedding_updated_at,
        request_id=request_id,
    )

    log_structured(
        "info",
        "Generated recommendation queue.",
        request_id=request_id,
        user_id=user_id,
        queue_size=len(new_queue),
    )
    return new_queue
