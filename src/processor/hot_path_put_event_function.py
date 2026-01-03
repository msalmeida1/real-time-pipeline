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

'''
This function is the hot path function and has the purpose of receiving hot events from the producer (interactions) and put them into Amazon Personalize for real-time model updates.
'''