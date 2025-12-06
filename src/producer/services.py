import boto3
import json
import os
import logging
import requests

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

def post_api_event(event):
    """
    Post event data to the specified API endpoint.
    Args:
        event (dict): Event data to be sent.
    Returns:
        requests.Response: Response object from the POST request.
    """
    url = "https://a1zru0y1ed.execute-api.us-east-1.amazonaws.com/dev/events"
    try:
        response = requests.post(url=url, json=event)
        response.raise_for_status()
        return response
    except requests.exceptions.RequestException as e:
        logger.error(f"Error posting event to API: {e}")
        return None