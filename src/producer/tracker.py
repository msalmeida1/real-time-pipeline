import time
import logging

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

class SpotifyTracker:
    def __init__(self):
        self.current_track_id = None
        self.current_track_name = None
        self.start_time = 0
        self.min_listen_time = 30 

    def check_status(self, spotify_data):
        """
        Check the current Spotify track status and determine if a track change event should be generated.
        Args:
            spotify_data (dict): Data returned by the Spotify API.
        Returns:
            dict or None: Track change event if a track change is detected, otherwise None.
        """

        if not spotify_data or not spotify_data.get('item'):
            return None

        now = time.time()
        track = spotify_data['item']
        track_id = track['id']
        track_name = track['name']
        
        event = None

        if self.current_track_id and track_id != self.current_track_id:
            duration = now - self.start_time
            
            status = 'SKIPPED' if duration < self.min_listen_time else 'COMPLETED'
            processing_path = 'hot' if status in ['SKIPPED', 'COMPLETED'] else 'cold'
            
            event = {
                'event_type': 'track_change',
                'track_id': self.current_track_id,
                'track_name': self.current_track_name,
                'status': status,
                'processing_path': processing_path,
                'duration_listened': int(duration),
                'timestamp': int(now)
            }

        if track_id != self.current_track_id:
            self.current_track_id = track_id
            self.current_track_name = track_name
            self.start_time = now
            logger.info(f"Now playing: {track_name}")

        return event
