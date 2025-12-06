import time
import logging

from producer.main import main as producer_main
from recommender.main import main as recommender_main

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
        producer_main()
        recommender_main()
        time.sleep(5)  