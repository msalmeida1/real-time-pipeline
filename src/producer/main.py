import time
import os
import logging

from auth import get_spotify_client  
from tracker import SpotifyTracker
from services import KinesisService

from dotenv import load_dotenv

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

load_dotenv()

def main():
    """
    Main function to monitor Spotify currently playing track and send events to Kinesis.
    """
    logger.info("Starting Spotify monitoring...")
    sp = get_spotify_client()
    kinesis = KinesisService()
    tracker = SpotifyTracker()
    
    user = sp.current_user()
    user_id = user['id']
    logger.info(f"User authenticated: {user['display_name']} ({user_id})")

    while True:
        try:
            current_track = sp.current_user_playing_track()
            
            event = tracker.check_status(current_track)
                
            if event:
                event['user_id'] = user_id

                logger.info(f"Track change detected: {event['track_name']} - {event['status']}")
                kinesis.send_event(event, partition_key=user_id)

            if current_track and current_track.get('is_playing'):
                logger.info(f"Currently playing: {current_track['item']['name']} by {', '.join(artist['name'] for artist in current_track['item']['artists'])}")


        except Exception as e:
            logger.error(f"Error fetching current track: {e}")

        time.sleep(5)

if __name__ == "__main__":
    main()