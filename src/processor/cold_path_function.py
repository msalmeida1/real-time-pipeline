import base64
import json
import logging
import os

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Firehose will set PROCESSING_PATH to either "hot" or "cold" depending on the
# delivery stream. Defaults to cold.
PROCESSING_PATH = os.environ.get("PROCESSING_PATH", "cold")

def transform_data(event):
    """
    Transforms the event data by selecting specific columns and flattening nested dictionaries.
    Args:
        event (dict): The event data.
    Returns:
        dict: Event with selected columns.
    """
    if event.get("processing_path") == 'hot':
        event = {
            'event_type': event.get('event_type'),
            'track_id': event.get('track_id'),
            'track_name': event.get('track_name'),
            'status': event.get('status'),
            'processing_path': event.get('processing_path'),
            'duration_listened': event.get('duration_listened'),
            'timestamp': event.get('timestamp'),
            'user_id': event.get('user_id')
        }
        return event
    
    event = {
        'is_playing': event.get('is_playing'),
        'timestamp': event.get('timestamp'),
        'progress_ms': event.get('progress_ms'),
        'item_album_artists': ", ".join([artist['name'] for artist in event.get('item', {}).get('album', {}).get('artists', [])]),
        'item_album_id': event.get('item', {}).get('album', {}).get('id'),
        'item_album_name': event.get('item', {}).get('album', {}).get('name'),
        'item_album_release_date': event.get('item', {}).get('album', {}).get('release_date'),
        'item_album_total_tracks': event.get('item', {}).get('album', {}).get('total_tracks'),
        'item_artists': ", ".join([artist['name'] for artist in event.get('item', {}).get('artists', [])]),
        'item_disc_number': event.get('item', {}).get('disc_number'),
        'item_duration_ms': event.get('item', {}).get('duration_ms'),
        'item_explicit': event.get('item', {}).get('explicit'),
        'item_external_ids_isrc': event.get('item', {}).get('external_ids', {}).get('isrc'),
        'item_id': event.get('item', {}).get('id'),
        'item_name': event.get('item', {}).get('name'),
        'item_popularity': event.get('item', {}).get('popularity'),
        'item_track_number': event.get('item', {}).get('track_number'),
        'item_type': event.get('item', {}).get('type'),
        'processing_path': event.get('processing_path'),
        'user_id': event.get('user_id')
    }
        
    return event

def lambda_handler(event, context):
    """Transform records from Firehose and drop anything outside PROCESSING_PATH."""
    transformed_records = []

    for record in event.get("records", []):
        record_id = record.get("recordId")
        try:
            raw_data = base64.b64decode(record["data"]).decode("utf-8")
            payload = json.loads(raw_data)

            if payload.get("processing_path") != PROCESSING_PATH:
                transformed_records.append(
                    {"recordId": record_id, "result": "Dropped", "data": record["data"]}
                )
                continue
            
            payload = transform_data(payload)
            user_id = payload.get("user_id", "unknown")
            prepared = json.dumps(payload) + "\n"
            encoded = base64.b64encode(prepared.encode("utf-8")).decode("utf-8")

            transformed_records.append(
                {
                    "recordId": record_id,
                    "result": "Ok",
                    "data": encoded,
                    "metadata": {"partitionKeys": {"user_id": user_id}},
                }
            )

        except Exception as exc:
            logger.error(f"Error transforming record {record_id}: {exc}")
            transformed_records.append(
                {
                    "recordId": record_id,
                    "result": "ProcessingFailed",
                    "data": record.get("data", ""),
                }
            )
            continue

    return {"records": transformed_records}
