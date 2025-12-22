import json
import boto3
import base64
import binascii
import os
import time
from decimal import Decimal, InvalidOperation
from typing import Any

import logging
from botocore.exceptions import BotoCoreError, ClientError

import spotipy
from spotipy.exceptions import SpotifyException
from spotipy.oauth2 import SpotifyClientCredentials
import requests

logger = logging.getLogger(__name__)
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(name)s - %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logging.getLogger().setLevel(logging.INFO)

SPOTIFY_SECRET_ID = os.environ.get("SPOTIFY_SECRET_ID")
EMBEDDING_VERSION = "v1"
DEFAULT_TEMPO_MIN = 50.0
DEFAULT_TEMPO_MAX = 200.0

secrets_manager = boto3.client("secretsmanager")
_spotify_client = None

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE')
profile_table = dynamodb.Table(TABLE_NAME)


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


def to_decimal(value: float) -> Decimal:
    """Convert a float to Decimal while preserving precision.

    Args:
        value: The float value to convert.

    Returns:
        The Decimal representation.
    """
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0")


def build_user_embedding(profile: dict, genre_vocab: list[str], tempo_min: float, tempo_max: float) -> tuple[list[Decimal], dict]:
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
    embedding = [to_decimal(value) for value in audio_vector + genre_vector]
    metadata = {
        "embedding_version": EMBEDDING_VERSION,
        "feature_order": feature_order,
        "genre_vocab": genre_vocab,
        "tempo_min": to_decimal(tempo_min),
        "tempo_max": to_decimal(tempo_max),
    }
    return embedding, metadata


def remove_track_from_queue(profile: dict, track_id: str) -> None:
    """Remove a track from the recommendation queue if present.

    Args:
        profile: The user profile document from DynamoDB.
        track_id: The track identifier to remove.

    Returns:
        None.
    """
    queue = profile.get("recommendation_queue", [])
    if not isinstance(queue, list):
        return
    cleaned_queue = []
    for item in queue:
        if isinstance(item, dict):
            if item.get("track_id") != track_id:
                cleaned_queue.append(item)
        elif isinstance(item, str):
            if item != track_id:
                cleaned_queue.append(item)
        else:
            cleaned_queue.append(item)
    profile["recommendation_queue"] = cleaned_queue


def get_spotify_client():
    """Initialize and return a Spotify client using credentials from AWS Secrets Manager.

    Returns:
        spotipy.Spotify: Authenticated Spotify client.

    Raises:
        ClientError: If AWS Secrets Manager access fails.
        BotoCoreError: If AWS SDK fails to retrieve secrets.
        RuntimeError: If required credentials are missing.
        json.JSONDecodeError: If the secret payload is not valid JSON.
        binascii.Error: If binary secret decoding fails.
    """
    global _spotify_client
    if _spotify_client:
        return _spotify_client

    if not SPOTIFY_SECRET_ID:
        raise RuntimeError("Missing SPOTIFY_SECRET_ID environment variable")

    try:
        secret_value = secrets_manager.get_secret_value(SecretId=SPOTIFY_SECRET_ID)
    except (ClientError, BotoCoreError) as exc:
        log_structured(
            "error",
            "Failed to fetch Spotify credentials from Secrets Manager.",
            secret_id=SPOTIFY_SECRET_ID,
            error=str(exc),
        )
        raise

    secret_string = secret_value.get("SecretString")
    if not secret_string and "SecretBinary" in secret_value:
        try:
            secret_string = base64.b64decode(secret_value["SecretBinary"]).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError) as exc:
            log_structured(
                "error",
                "Failed to decode Spotify secret binary payload.",
                secret_id=SPOTIFY_SECRET_ID,
                error=str(exc),
            )
            raise

    try:
        creds = json.loads(secret_string or "{}")
    except json.JSONDecodeError as exc:
        log_structured(
            "error",
            "Failed to parse Spotify secret payload as JSON.",
            secret_id=SPOTIFY_SECRET_ID,
            error=str(exc),
        )
        raise

    client_id = creds.get("SPOTIFY_CLIENT_ID")
    client_secret = creds.get("SPOTIFY_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise RuntimeError("Secret missing client_id or client_secret fields")

    auth = SpotifyClientCredentials(
        client_id=client_id,
        client_secret=client_secret
    )
    _spotify_client = spotipy.Spotify(client_credentials_manager=auth)
    return _spotify_client


def track_metadata(track_id: str, user_id: str | None = None):
    """Fetch track audio features and artist genres from Spotify API.

    Args:
        track_id: The Spotify track ID.
        user_id: The user identifier for correlation.

    Returns:
        A tuple of (audio_features, genres, track_info, artist_info), or None on error.
    """
    try:
        spotify_client = get_spotify_client()
        features_list = spotify_client.audio_features([track_id])
        if not features_list or features_list[0] is None:
            log_structured(
                "warning",
                "Spotify returned empty audio features.",
                track_id=track_id,
                user_id=user_id,
            )
            return None
        features = features_list[0]
        track_info = spotify_client.track(track_id)
        artist_id = track_info["artists"][0]["id"]
        artist_info = spotify_client.artist(artist_id)
        genres = artist_info.get("genres", [])

        return features, genres, track_info, artist_info

    except (SpotifyException, requests.exceptions.RequestException, KeyError, IndexError, TypeError) as exc:
        log_structured(
            "error",
            "Failed to fetch Spotify metadata.",
            track_id=track_id,
            user_id=user_id,
            error=str(exc),
        )
        return None


def update_audio_profile(current_profile: dict, new_features: dict) -> dict:
    """Update audio profile averages with new track features.

    Args:
        current_profile: Existing audio profile with averages and sample count.
        new_features: Audio features of the new track.

    Returns:
        Updated audio profile with new averages and sample count.
    """
    stats = current_profile.get("audio_profile", {
        "avg_danceability": 0,
        "avg_energy": 0,
        "avg_valence": 0,
        "avg_acousticness": 0,
        "avg_tempo": 0,
        "samples": 0,
    })

    samples = int(safe_float(stats.get("samples", 0)))

    def calc_avg(key: str) -> Decimal:
        """Calculate the updated average for a given audio feature.

        Args:
            key: The audio feature key to update.

        Returns:
            The updated average as a Decimal.
        """
        old_avg = safe_float(stats.get(f"avg_{key}", 0))
        new_val = safe_float(new_features.get(key, 0))
        updated = (old_avg * samples + new_val) / (samples + 1) if (samples + 1) > 0 else 0.0
        return Decimal(str(updated))

    stats["avg_danceability"] = calc_avg("danceability")
    stats["avg_energy"] = calc_avg("energy")
    stats["avg_valence"] = calc_avg("valence")
    stats["avg_acousticness"] = calc_avg("acousticness")
    stats["avg_tempo"] = calc_avg("tempo")
    stats["samples"] = samples + 1

    return stats


def update_genre_affinity(current_genres: dict, new_genres: list[str]) -> dict:
    """
    Update genre affinity counts.
    Args:
        current_genres (dict): Existing genre counts.
        new_genres (list): List of genres from the new track.
    Returns:
        dict: Updated genre counts.
    """
    current_genres = current_genres or {}
    for genre in new_genres:
        safe_genre = genre.replace(" ", "_")
        current_genres[safe_genre] = current_genres.get(safe_genre, 0) + 1
    return current_genres

def update_artist_affinity(current_artists: list[str], new_artists: dict) -> dict:
    """
    Update artist affinity data.
    Args:
        current_artists (list): Existing artist data.
        new_artists (dict): Dict of artist data from the new track.
    Returns:
        list: Updated artist data.
    """
    current_artists = current_artists or []
    artist_map = {artist['artist_id']: artist for artist in current_artists}
    now = int(time.time())
    artist_id = new_artists['id']

    if artist_id not in artist_map:
        artist_map[artist_id] = {
            'artist_id': artist_id,
            'name': new_artists['name'],
            'affinity': 1,
            'last_played_ts': now
        }
    else:
        artist_map[artist_id]['affinity'] += 1
        artist_map[artist_id]['last_played_ts'] = now

    return current_artists


def update_user_profile(user_id: str, track_id: str, status: str, request_id: str | None = None) -> None:
    """Update the user profile in DynamoDB based on a track play event.

    Args:
        user_id: The user's unique identifier.
        track_id: The Spotify track ID.
        status: The track status ("COMPLETED" or "SKIPPED").
        request_id: The Lambda request ID for correlation.

    Returns:
        None.

    Raises:
        None.
    """
    now = int(time.time())
    log_context = {"user_id": user_id, "request_id": request_id, "track_id": track_id}

    try:
        resp = profile_table.get_item(Key={"user_id": user_id})
        profile = resp.get("Item", {
            "user_id": user_id,
            "created_at": now,
            "updated_at": now,
            "last_event_ts": now,
            "audio_profile": {"samples": 0},
            "genre_affinity": {},
            "artist_affinity": [],
            "recent_history": [],
            "total_tracks_played": 0,
            "total_completions": 0,
            "total_skips": 0,
            "recommendation_queue": [],
            "queue_updated_at": 0,
            "queue_embedding_version": "",
            "queue_embedding_ts": 0,
        })
    except (ClientError, BotoCoreError) as exc:
        log_structured(
            "error",
            "Failed to fetch user profile from DynamoDB.",
            **log_context,
            error=str(exc),
        )
        return

    profile['updated_at'] = now
    profile['last_event_ts'] = now
    profile['total_tracks_played'] = profile.get('total_tracks_played', 0) + 1
    
    if status == 'COMPLETED':
        profile['total_completions'] = profile.get('total_completions', 0) + 1

        meta = track_metadata(track_id, user_id=user_id)
        if meta:
            features, genres, track_info, artist_info = meta

            profile['audio_profile'] = update_audio_profile(profile, features)

            profile['genre_affinity'] = update_genre_affinity(
                profile.get('genre_affinity', {}),
                genres,
            )

            profile['artist_affinity'] = update_artist_affinity(
                profile.get('artist_affinity', []),
                artist_info
            )

    elif status == 'SKIPPED':
        profile['total_skips'] = profile.get('total_skips', 0) + 1

    new_history_item = {'track_id': track_id, 'status': status, 'ts': now}
    history = profile.get('recent_history', [])
    history.insert(0, new_history_item)  
    profile['recent_history'] = history[:20] 
    remove_track_from_queue(profile, track_id)

    genre_vocab = parse_genre_vocab()
    tempo_min, tempo_max = get_tempo_bounds()
    user_embedding, embedding_meta = build_user_embedding(profile, genre_vocab, tempo_min, tempo_max)
    profile["user_embedding"] = user_embedding
    profile["embedding_meta"] = embedding_meta
    profile["embedding_version"] = EMBEDDING_VERSION
    profile["embedding_updated_at"] = now

    try:
        profile_table.put_item(Item=profile)
    except (ClientError, BotoCoreError) as exc:
        log_structured(
            "error",
            "Failed to write user profile to DynamoDB.",
            **log_context,
            error=str(exc),
        )
        return

    log_structured("info", "Updated user profile.", **log_context, status=status)


def lambda_handler(event, context):
    """Process Kinesis records for hot path user profile updates.

    Args:
        event: The event payload from Kinesis.
        context: The runtime information of the Lambda function.

    Returns:
        A response dict with status code and body.

    Raises:
        None.
    """
    records_to_process = event.get("Records", [])
    request_id = getattr(context, "aws_request_id", None)
    log_structured(
        "info",
        "Received Kinesis batch.",
        request_id=request_id,
        record_count=len(records_to_process),
    )

    for record in records_to_process:
        try:
            kinesis_data = record["kinesis"]["data"]
            decoded_data = base64.b64decode(kinesis_data).decode("utf-8")
            payload = json.loads(decoded_data, parse_float=Decimal)
        except (KeyError, ValueError, json.JSONDecodeError, UnicodeDecodeError, binascii.Error) as exc:
            log_structured(
                "error",
                "Failed to decode Kinesis record.",
                request_id=request_id,
                error=str(exc),
            )
            continue

        processing_path = payload.get("processing_path")
        if processing_path != "hot":
            continue

        track_id = payload.get("track_id")
        status = payload.get("status")
        user_id = payload.get("user_id")
        if not user_id or not track_id or not status:
            log_structured(
                "warning",
                "Skipping record with missing required fields.",
                request_id=request_id,
                user_id=user_id,
                track_id=track_id,
            )
            continue

        update_user_profile(user_id, track_id, status, request_id=request_id)

    return {
        "statusCode": 200,
        "body": json.dumps(f"Processed {len(records_to_process)} records."),
    }
