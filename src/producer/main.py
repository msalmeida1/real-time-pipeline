import time
import logging

from auth import get_spotify_client  
from tracker import SpotifyTracker
from services import post_api_event

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
    tracker = SpotifyTracker()
    
    user = sp.current_user()
    user_id = user['id']
    logger.info(f"User authenticated: {user['display_name']} ({user_id})")

    try:
        current_track = sp.current_user_playing_track()
        
        event = tracker.check_status(current_track)
            
        if event and event.get('processing_path') == 'hot':
            event['user_id'] = user_id

            logger.info(f"Sending hot-path event for track: {event['track_name']}")
            post_api_event(event)

        else:
            current_track['user_id'] = user_id
            current_track['processing_path'] = 'cold'

            logger.info(f"Sending cold-path event for track: {current_track['item']['name']}")
            post_api_event(current_track)

        if current_track and current_track.get('is_playing'):
            logger.info(f"Currently playing: {current_track['item']['name']} by {', '.join(artist['name'] for artist in current_track['item']['artists'])}")


    except Exception as e:
        logger.error(f"Error fetching current track: {e}")


if __name__ == "__main__":
    main()