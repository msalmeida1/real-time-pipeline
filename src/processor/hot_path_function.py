import json
import boto3
import base64
import os
import time
from decimal import Decimal

import logging

import spotipy
from spotipy.oauth2 import SpotifyClientCredentials

logger = logging.getLogger(__name__)
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(name)s - %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logging.getLogger().setLevel(logging.INFO)

sp_auth = SpotifyClientCredentials(
    client_id=os.environ.get('SPOTIFY_CLIENT_ID'),
    client_secret=os.environ.get('SPOTIFY_CLIENT_SECRET')
)
sp = spotipy.Spotify(client_credentials_manager=sp_auth)

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE')
profile_table = dynamodb.Table(TABLE_NAME)


def track_metadata(track_id: str):
    """
    Fetch track audio features and artist genres from Spotify API.
    Args:
        track_id (str): The Spotify track ID.
    Returns:
        tuple: (audio_features, genres, track_info, artist_info) or None on error
    """
    try:
        features = sp.audio_features([track_id])[0]
        track_info = sp.track(track_id)
        artist_id = track_info['artists'][0]['id']
        artist_info = sp.artist(artist_id)
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
            'artist_affinity': [],
            'recent_history': [],
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

            processing_path = payload.get('processing_path')
            if processing_path != 'hot':
                continue      

            track_id = payload['track_id']
            status = payload['status']
            user_id = payload['user_id']

            update_user_profile(user_id, track_id, status)

        except Exception as e:
            logger.exception(f"Error processing record: {e}")

    return {
        'statusCode': 200,
        'body': json.dumps(f'Processed {len(records_to_process)} records.')
    }
