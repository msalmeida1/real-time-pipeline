import json
import boto3
import base64
import os
import logging
from decimal import Decimal

logger = logging.getLogger()

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE', 'SpotifyEvents')
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    """
    Handler for processing Kinesis events.
    Args:
        event (dict): Event received from Kinesis.
        context (LambdaContext): Lambda execution context.
    Returns:
        dict: Execution result.
    """
    records_to_process = event['Records']
    logger.info(f"Received batch with {len(records_to_process)} lines from Kinesis.")

    for record in records_to_process:
        try:

            kinesis_data = record['kinesis']['data']
            decoded_data = base64.b64decode(kinesis_data).decode('utf-8')
            payload = json.loads(decoded_data, parse_float=Decimal)

            # future business logic
            
            user_id = payload['user_id']
            timestamp = payload['timestamp']
            track_name = payload['track_name']

            logger.info(f"Saving: {user_id} listened to {track_name}")

            table.put_item(Item=payload)

        except Exception as e:
            logger.info(f"Error processing registry: {e}")

    return {
        'statusCode': 200,
        'body': json.dumps(f'Processados {len(records_to_process)} registros.')
    }