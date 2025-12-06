import logging
import requests

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

def get_api_recommendations(user_id):
    """
    Get recommendations from the recommender system API for a given user.
    Args:
        user_id (str): The user ID for whom to get recommendations.
    Returns:
        dict: Recommendations data from the API.
    """
    url = f"https://a1zru0y1ed.execute-api.us-east-1.amazonaws.com/dev/recommendations/{user_id}"
    try:
        response = requests.get(url=url)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Error fetching recommendations from API: {e}")
        return None