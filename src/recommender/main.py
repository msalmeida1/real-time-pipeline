import json
import logging
import os

try:
    from recommender.services import get_recommendation_queue
except ModuleNotFoundError:
    from services import get_recommendation_queue

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

logger = logging.getLogger(__name__)


def main():
    """Generate a recommendation queue for a configured user.

    Args:
        None.

    Returns:
        None.
    """
    user_id = os.environ.get("RECOMMENDER_USER_ID", "")
    if not user_id:
        logger.warning(
            json.dumps(
                {
                    "message": "Missing RECOMMENDER_USER_ID; skipping recommendations.",
                },
                ensure_ascii=True,
            )
        )
        return

    queue_size_raw = os.environ.get("RECOMMENDER_QUEUE_SIZE", "10")
    try:
        queue_size = int(queue_size_raw)
    except ValueError:
        queue_size = 10

    queue = get_recommendation_queue(user_id, queue_size=queue_size)
    logger.info(
        json.dumps(
            {
                "message": "Recommendation queue generated.",
                "user_id": user_id,
                "queue_size": len(queue),
            },
            ensure_ascii=True,
        )
    )
