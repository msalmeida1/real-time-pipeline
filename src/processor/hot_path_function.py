import json
import boto3
import base64
import os
import logging
from decimal import Decimal

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_TABLE', 'SpotifyEvents')
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    """
    Handler for processing Kinesis hot path events.
    Args:
        event (dict): Event received from Kinesis.
        context (LambdaContext): Lambda execution context.
    Returns:
        dict: Execution result.
    """
    logger.info(f"Lambda triggered with event: {json.dumps(event)}")
    records_to_process = event['Records']
    logger.info(f"Received batch with {len(records_to_process)} lines from Kinesis.")

    for record in records_to_process:
        try:

            kinesis_data = record['kinesis']['data']
            decoded_data = base64.b64decode(kinesis_data).decode('utf-8')
            payload = json.loads(decoded_data, parse_float=Decimal)

            processing_path = payload.get('processing_path', 'hot')
            if processing_path != 'hot':
                logger.info(f"Skipping cold-path event for DynamoDB: {payload}")
                continue
            
            user_id = payload['user_id']
            track_name = payload['track_name']

            logger.info(f"Saving: {user_id} listened to {track_name}")

            table.put_item(Item=payload)

        except Exception as e:
            logger.exception(f"Error processing registry: {e}")

    return {
        'statusCode': 200,
        'body': json.dumps(f'Processados {len(records_to_process)} registros.')
    }
