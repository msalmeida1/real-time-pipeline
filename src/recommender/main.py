import logging

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

def main():
    """
    Main function to get recommendations from the recommender system and form a queue.
    """
    logger.info("Starting recommender system...")
