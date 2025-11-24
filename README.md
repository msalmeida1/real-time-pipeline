# Serverless Real-Time Music Analytics Pipeline

Serverless pipeline that captures the Spotify track currently playing for an authenticated user, streams events through Amazon Kinesis, processes them with AWS Lambda, and lands enriched metrics in DynamoDB. The project is designed as a resume-ready example of real-time clickstream/telemetry processing with elastic, fully managed services.

## What this project demonstrates
- Polling Spotify's `current-user-playing` endpoint and deriving playback events (completed vs skipped) from listen time.
- Publishing user playback events to Kinesis Data Streams (buffering and fan-out ready for additional consumers).
- Lambda consumer that decodes Kinesis batches and persists normalized events to a DynamoDB table.
- Infrastructure-as-Code with Terraform for Kinesis, DynamoDB, Lambda, IAM, and CloudWatch logging.
- Python 3.11 codebase with clear separation between producer (client-side) and processor (serverless) concerns.

## Architecture
```
Spotify API → Python Producer → Kinesis Data Stream → Lambda Processor → DynamoDB
                                   │
                                   └─ CloudWatch Logs (observability)
```

## Repository layout
- `src/producer/` — Spotify client auth (`auth.py`), playback tracker (`tracker.py`), and publisher entrypoint (`main.py`) that can push to Kinesis.
- `src/processor/` — Lambda handler (`function.py`) that reads Kinesis records, applies business rules, and writes to DynamoDB.
- `infrastructure/` — Terraform to provision Kinesis, DynamoDB, Lambda, IAM role/policy, and event source mapping.
- `pyproject.toml`, `uv.lock` — Python dependencies (works with `uv` or `pip`).

## Prerequisites
- Python 3.11+
- Terraform >= 1.2
- AWS account with credentials configured locally (for Terraform and Kinesis/Lambda/DynamoDB access)
- Spotify Developer application with `user-read-currently-playing` scope enabled
- Optional: `uv` (recommended) or `pip` for Python dependency management

## Local setup
1) Clone the repository and create a virtual environment:
```bash
python -m venv .venv
source .venv/bin/activate
```

# Using uv (preferred)
```bash
uv init
```
2) Install dependencies (choose one):
```bash
# Using uv (preferred)
uv pip install -e .

# Using pip
pip install
```
3) Add a `.env` file in the project root with the required credentials:
```bash
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SPOTIFY_REDIRECT_URI=your_redirect_uri
AWS_REGION=us-east-1
KINESIS_STREAM_NAME=SpotifyStream
```
Your AWS credentials/profile should be available to the SDK (e.g., via `~/.aws/credentials` or environment variables).

## Running the local producer
The producer polls Spotify every 5 seconds and derives events when a track changes. Events are marked `COMPLETED` when listened for at least 30 seconds; otherwise they are `SKIPPED`.
```bash
python src/producer/main.py
```
- By default the Kinesis publish call in `src/producer/main.py` is commented out to avoid unintended AWS writes. If your stream is provisioned, uncomment the `KinesisService` lines to start sending events.
- Logged output includes the current track and any emitted track-change events (with user id attached).

## Deploying the AWS stack with Terraform
From `infrastructure/`:
```bash
terraform init
terraform apply
```
- Provisions Kinesis (`SpotifyStream`), DynamoDB (`SpotifyEvents`), Lambda processor, IAM role/policy, and event source mapping.
- The Lambda package is zipped from the processor code; ensure the `archive_file` source path aligns with `src/processor/function.py` if you adjust filenames.
- Remember to destroy resources when finished (`terraform destroy`) to avoid ongoing cloud charges.

## Event contract
Example payload emitted by the producer and stored by the Lambda processor:
```json
{
  "event_type": "track_change",
  "track_name": "My Song",
  "track_id": "spotify_track_id",
  "status": "COMPLETED",
  "duration_listened": 142,
  "timestamp": 1731100000,
  "user_id": "spotify_user_id"
}
```

## How the processor works
- Triggered by Kinesis batches via event source mapping.
- Decodes base64 Kinesis records, parses JSON, applies business rules (placeholder for enrichments), and writes to DynamoDB.
- Uses `boto3` with the table name supplied via the `DYNAMODB_TABLE` environment variable.

## Next steps and polish ideas
- Add unit tests/mocks around the producer tracker logic and the Lambda handler.
- Expand the processor to enrich events (e.g., artist/genre lookups) and emit aggregates to downstream sinks.
- Wire dashboards/alerts with CloudWatch or export to Amazon QuickSight/Athena for ad-hoc analysis.
- Add CI to lint/test and to package/deploy the Lambda automatically on Terraform apply.