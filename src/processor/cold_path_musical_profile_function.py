import base64
import binascii
import json
import os
import time
from decimal import Decimal

import logging

import boto3
from botocore.exceptions import ClientError
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials

logger = logging.getLogger(__name__)
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(name)s - %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logging.getLogger().setLevel(logging.INFO)

SPOTIFY_SECRET_ID = os.environ.get("SPOTIFY_SECRET_ID")

secrets_manager = boto3.client("secretsmanager")
_spotify_client = None

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE')
profile_table = dynamodb.Table(TABLE_NAME)

def get_spotify_client():
    """Initialize and return a Spotify client using credentials from AWS Secrets Manager.

    Args:
        None.

    Returns:
        spotipy.Spotify: Authenticated Spotify client.

    Raises:
        RuntimeError: If required configuration is missing.
        ClientError: If Secrets Manager returns an error.
        json.JSONDecodeError: If the secret payload is not valid JSON.
        UnicodeDecodeError: If the secret binary cannot be decoded as UTF-8.
        binascii.Error: If the secret binary cannot be base64-decoded.
    """
    global _spotify_client
    if _spotify_client:
        return _spotify_client

    if not SPOTIFY_SECRET_ID:
        logger.error(
            json.dumps(
                {
                    "message": "Missing SPOTIFY_SECRET_ID environment variable.",
                    "spotify_secret_id": SPOTIFY_SECRET_ID,
                }
            )
        )
        raise RuntimeError("Missing SPOTIFY_SECRET_ID environment variable.")

    try:
        secret_value = secrets_manager.get_secret_value(SecretId=SPOTIFY_SECRET_ID)
        secret_string = secret_value.get("SecretString")
        if not secret_string and "SecretBinary" in secret_value:
            secret_string = base64.b64decode(secret_value["SecretBinary"]).decode("utf-8")

        creds = json.loads(secret_string or "{}")
        client_id = creds.get("SPOTIFY_CLIENT_ID")
        client_secret = creds.get("SPOTIFY_CLIENT_SECRET")
    except (ClientError, json.JSONDecodeError, UnicodeDecodeError, binascii.Error) as exc:
        logger.error(
            json.dumps(
                {
                    "message": "Failed to load Spotify credentials from Secrets Manager.",
                    "spotify_secret_id": SPOTIFY_SECRET_ID,
                    "error": str(exc),
                    "error_type": type(exc).__name__,
                }
            ),
            exc_info=True,
        )
        raise

    if not client_id or not client_secret:
        logger.error(
            json.dumps(
                {
                    "message": "Secret missing SPOTIFY_CLIENT_ID or SPOTIFY_CLIENT_SECRET fields.",
                    "spotify_secret_id": SPOTIFY_SECRET_ID,
                }
            )
        )
        raise RuntimeError("Secret missing SPOTIFY_CLIENT_ID or SPOTIFY_CLIENT_SECRET fields.")

    auth = SpotifyClientCredentials(
        client_id=client_id,
        client_secret=client_secret,
    )
    _spotify_client = spotipy.Spotify(client_credentials_manager=auth)
    return _spotify_client


def track_metadata(track_id: str):
    """
    Fetch track audio features and artist genres from Spotify API.
    Args:
        track_id (str): The Spotify track ID.
    Returns:
        tuple: (audio_features, genres, track_info, artist_info) or None on error
    """
    try:
        spotify_client = get_spotify_client()
        features = spotify_client.audio_features([track_id])[0]
        track_info = spotify_client.track(track_id)
        artist_id = track_info['artists'][0]['id']
        artist_info = spotify_client.artist(artist_id)
        genres = artist_info.get('genres', [])

        return features, genres, track_info, artist_info

    except Exception as e:
        logger.error(f"Error fetching metadata for track {track_id}: {e}")
        return None


def update_audio_profile(current_profile: dict, new_features: dict) -> dict:
    """
    Update audio profile averages with new track features.
    Args:
        current_profile (dict): Existing audio profile with averages and sample count.
        new_features (dict): Audio features of the new track.
    Returns:
        dict: Updated audio profile with new averages and sample count.
    """
    stats = current_profile.get('audio_profile', {
        'avg_danceability': 0,
        'avg_energy': 0,
        'avg_loudness': 0,
        'avg_speechiness': 0,
        'avg_instrumentalness': 0,
        'avg_liveness': 0,
        'avg_valence': 0,
        'avg_acousticness': 0,
        'avg_tempo': 0,
        'samples': 0,
    })
    
    samples = stats.get('samples', 0)

    def calc_avg(key: str) -> Decimal:
        old_avg = float(stats.get(f'avg_{key}', 0))
        new_val = float(new_features.get(key, 0))
        return Decimal(str((old_avg * samples + new_val) / (samples + 1))) if (samples + 1) > 0 else Decimal("0")

    stats['avg_danceability'] = calc_avg('danceability')
    stats['avg_energy'] = calc_avg('energy')
    stats['avg_loudness'] = calc_avg('loudness')
    stats['avg_speechiness'] = calc_avg('speechiness')
    stats['avg_instrumentalness'] = calc_avg('instrumentalness')
    stats['avg_liveness'] = calc_avg('liveness')
    stats['avg_valence'] = calc_avg('valence')
    stats['avg_acousticness'] = calc_avg('acousticness')
    stats['avg_tempo'] = calc_avg('tempo')
    stats['samples'] = samples + 1
    
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

def update_user_profile(user_id: str, track_id: str, status: str) -> None:
    """
    Update user profile in DynamoDB based on track play event.
    Args:
        user_id (str): The user's unique identifier.
        track_id (str): The Spotify track ID.
        status (str): 'COMPLETED' or 'SKIPPED'.
    Returns:
        None
    """
    now = int(time.time())
    
    try:
        resp = profile_table.get_item(Key={'user_id': user_id})
        profile = resp.get('Item', {
            'user_id': user_id,
            'created_at': now,
            'updated_at': now,
            'last_event_ts': now,
            'audio_profile': {'samples': 0},
            'genre_affinity': {},
            'total_tracks_played': 0,
            'total_completions': 0,
            'total_skips': 0,
        })
    except Exception as e:
        logger.exception(f"Error fetching profile for user {user_id}: {e}")
        return

    profile['updated_at'] = now
    profile['last_event_ts'] = now
    profile['total_tracks_played'] = profile.get('total_tracks_played', 0) + 1
    
    if status == 'COMPLETED':
        profile['total_completions'] = profile.get('total_completions', 0) + 1

        meta = track_metadata(track_id)
        if meta:
            features, genres, track_info, artist_info = meta

            profile['audio_profile'] = update_audio_profile(profile, features)

            profile['genre_affinity'] = update_genre_affinity(
                profile.get('genre_affinity', {}),
                genres,
            )

    elif status == 'SKIPPED':
        profile['total_skips'] = profile.get('total_skips', 0) + 1

    profile_table.put_item(Item=profile)
    logger.info(f"Updated profile for user {user_id}")


def lambda_handler(event, context):
    """
    Lambda function to process Kinesis records for hot path user profile updates.
    Args:
        event (dict): The event payload from Kinesis.
        context (object): The runtime information of the Lambda function.
    Returns:
        dict: Response with status code and body.
    """
    records_to_process = event['Records']
    logger.info(f"Received batch with {len(records_to_process)} records from Kinesis.")

    for record in records_to_process:
        try:
            kinesis_data = record['kinesis']['data']
            decoded_data = base64.b64decode(kinesis_data).decode('utf-8')
            payload = json.loads(decoded_data, parse_float=Decimal)  
            track_id = payload['track_id']
            status = payload['status']
            user_id = payload['user_id']

            if status not in ['COMPLETED', 'SKIPPED']:
                logger.warning(f"Dropping record with unsupported status: {status}")
                continue

            update_user_profile(user_id, track_id, status)

        except Exception as e:
            logger.exception(f"Error processing record: {e}")

    return {
        'statusCode': 200,
        'body': json.dumps(f'Processed {len(records_to_process)} records.')
    }
