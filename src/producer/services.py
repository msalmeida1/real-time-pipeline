import boto3
import json
import os
import logging

logging.basicConfig(
    level=logging.INFO, 
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)

class KinesisService:
    def __init__(self):
        self.client = boto3.client('kinesis', region_name=os.getenv('AWS_REGION', 'us-east-1'))
        self.stream_name = os.getenv('KINESIS_STREAM_NAME')

    def send_event(self, event_data, partition_key):
        if not self.stream_name:
            logger.info("Kinesis stream name not configured.")
            return

        try:
            self.client.put_record(
                StreamName=self.stream_name,
                Data=json.dumps(event_data),
                PartitionKey=str(partition_key)
            )
        except Exception as e:
            logger.error(f"Error sending event to Kinesis: {e}")