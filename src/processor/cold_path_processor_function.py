import base64
import binascii
import json
import logging
import os

logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
)
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logging.getLogger().setLevel(logging.INFO)

def transform_data(event):
    """
    Transforms the event data by selecting specific columns and flattening nested dictionaries.
    Args:
        event (dict): The event data.
    Returns:
        dict: Event with selected columns.
    """
    event = {
        'track_id': event.get('track_id'),
        'track_name': event.get('track_name'),
        'status': event.get('status'),
        'duration_listened': event.get('duration_listened'),
        'user_id': event.get('user_id'),
        'timestamp': event.get('timestamp')
    }
        
    return event

def lambda_handler(event, context):
    """
    Transform records from Firehose and drop anything outside STATUS.
    Args:
        event (dict): Event received from Firehose.
        context (LambdaContext): Lambda execution context.
    Returns:
        dict: Transformed records.
    """
    transformed_records = []
    request_id = getattr(context, "aws_request_id", "unknown")

    for record in event.get("records", []):
        record_id = record.get("recordId")
        status = None
        user_id = None
        try:
            raw_data = base64.b64decode(record["data"]).decode("utf-8")
            payload = json.loads(raw_data)
            status = payload.get("status")

            logger.info(
                json.dumps(
                    {
                        "message": "Processing record.",
                        "request_id": request_id,
                        "record_id": record_id,
                        "status": status,
                    }
                )
            )

            if status not in ["SKIPPED", "COMPLETED"]:
                logger.warning(
                    json.dumps(
                        {
                            "message": "Dropping record with unsupported status.",
                            "request_id": request_id,
                            "record_id": record_id,
                            "status": status,
                        }
                    )
                )
                transformed_records.append(
                    {"recordId": record_id, "result": "Dropped", "data": record["data"]}
                )
                continue
            
            payload = transform_data(payload)
            status = payload.get("status")
            user_id = payload.get("user_id")
            prepared = json.dumps(payload) + "\n"
            encoded = base64.b64encode(prepared.encode("utf-8")).decode("utf-8")

            transformed_records.append(
                {
                    "recordId": record_id,
                    "result": "Ok",
                    "data": encoded,
                    "metadata": {"partitionKeys": {"status": status, "user_id": user_id}},
                }
            )
            logger.info(
                json.dumps(
                    {
                        "message": "Successfully transformed record.",
                        "request_id": request_id,
                        "record_id": record_id,
                        "status": status,
                        "user_id": user_id,
                    }
                )
            )

        except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError, UnicodeDecodeError, binascii.Error) as exc:
            logger.error(
                json.dumps(
                    {
                        "message": "Error transforming record.",
                        "request_id": request_id,
                        "record_id": record_id,
                        "status": status,
                        "user_id": user_id,
                        "error": str(exc),
                        "error_type": type(exc).__name__,
                    }
                )
            )
            transformed_records.append(
                {
                    "recordId": record_id,
                    "result": "ProcessingFailed",
                    "data": record.get("data", ""),
                }
            )
            continue

    return {"records": transformed_records}
