import time
import json
import os
import boto3
import logging
from botocore.exceptions import ClientError
from auth_manager import get_spotify_client
from dotenv import load_dotenv

logger = logging.getLogger()

load_dotenv()

AWS_REGION = os.getenv('AWS_REGION')
STREAM_NAME = os.getenv('KINESIS_STREAM_NAME')

def create_kinesis_client():
    """
    Create and return a Kinesis client.
    Returns: boto3 Kinesis client.
    """
    return boto3.client('kinesis', region_name=AWS_REGION)

def format_event(track_data, user_id):
    """
    Format the current track data into a structured dictionary for sending to Kinesis.
    Args:
        track_data (dict): Data returned by the Spotify API.
        user_id (str): Spotify user ID.
    Returns:
        dict: Formatted event or None if no track is playing.
    """
    if not track_data or not track_data.get('item'):
        return None

    item = track_data['item']
    
    return {
        'event_type': 'listen_heartbeat',
        'user_id': user_id,
        'track_id': item['id'],
        'track_name': item['name'],
        'artist': item['artists'][0]['name'],
        'album': item['album']['name'],
        'duration_ms': item['duration_ms'],
        'progress_ms': track_data['progress_ms'],
        'is_playing': track_data['is_playing'],
        'timestamp': int(time.time()) 
    }

def main():
    logger.info("Starting Spotify monitoring...")
    sp = get_spotify_client()
    kinesis = create_kinesis_client()
    
    user = sp.current_user()
    user_id = user['id']
    logger.info(f"User authenticated: {user['display_name']} ({user_id})")

    while True:
        try:
            current_track = sp.current_user_playing_track()
            
            if current_track is not None:
                event = format_event(current_track, user_id)
                
                if event:
                    payload = json.dumps(event)
                    logger.info(f"Playing: {event['track_name']} - {event['artist']} [{event['progress_ms']}ms]")
                    with open('payload.json', 'w') as f:
                        f.write(payload)

                    try:
                        kinesis.put_record(
                            StreamName=STREAM_NAME,
                            Data=payload,
                            PartitionKey=user_id 
                        )

                    except ClientError as e:
                        if e.response['Error']['Code'] == 'ResourceNotFoundException':
                            logger.error(f"Stream {STREAM_NAME} not found.")
                        else:
                            logger.error(f"Failed to send record to Kinesis: {e}")
            else:
                logger.info("No music playing...")

        except Exception as e:
            logger.info(f"Error fetching current track: {e}")

        time.sleep(5)

if __name__ == "__main__":
    main()