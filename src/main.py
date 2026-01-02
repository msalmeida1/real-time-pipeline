import time
import logging

from producer.main import main as producer
from recommender.main import main as recommender

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

def main():
    """
    Main function to monitor Spotify currently playing track and get recommendations.
    """
    logger.info("Starting main application...")
    
    while True:
        producer()
        recommender()
        time.sleep(5)