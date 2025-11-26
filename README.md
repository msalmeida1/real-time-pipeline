# Serverless Real-Time Music Analytics Pipeline

Serverless pipeline that captures the Spotify track currently playing for an authenticated user, streams events through Amazon Kinesis, bifurcates events into hot and cold paths, and lands enriched metrics in DynamoDB (hot) or S3/Glacier (cold) as Parquet. Built as a concise reference implementation of real-time clickstream/telemetry processing with elastic, fully managed services.

## What this project demonstrates
![Architecture Diagram](docs/architecture.png)
- Polling Spotify's `current-user-playing` endpoint and deriving playback events (completed vs skipped) from listen time.
- Publishing user playback events to Kinesis Data Streams (buffering and fan-out ready for additional consumers).
- Lambda consumer that decodes Kinesis batches and persists normalized events to a DynamoDB table.
- Infrastructure-as-Code with Terraform for Kinesis, DynamoDB, Lambda, IAM, and CloudWatch logging.
- Python 3.11 codebase with clear separation between producer (client-side) and processor (serverless) concerns.

## Architecture
```
Spotify API → Python Producer → Kinesis Data Stream
                                    ├─ Lambda (hot_path_function) → DynamoDB (hot path)
                                    └─ 2× Kinesis Firehose (Lambda transform) → S3 (Parquet, dynamic partitioning by user_id, lifecycle → Glacier) (cold & hot archival)
                                                              │
                                                              └─ Glue Catalog (Parquet schema)
```

## Repository layout
- `src/producer/` — Spotify client auth (`auth.py`), playback tracker (`tracker.py`), and publisher entrypoint (`main.py`) that can push to Kinesis.
- `src/processor/` — Lambda handlers: `hot_path_function.py` (hot path to DynamoDB) and `cold_path_function.py` (Firehose transform shared by hot/cold Firehoses, filtered via `PROCESSING_PATH` env).
- `infrastructure/` — Terraform to provision Kinesis, DynamoDB, Lambdas, Firehoses (hot/cold), S3 buckets (hot/cold), Glue catalog tables, IAM, and event source mapping.
- `pyproject.toml`, `uv.lock` — Python dependencies (works with `uv` or `pip`).

## Prerequisites
- Python 3.11+
- Terraform >= 1.2
- AWS account with credentials configured locally (for Terraform and Kinesis/Lambda/DynamoDB access)
- Spotify Developer application with `user-read-currently-playing` scope enabled
- Optional: `uv` (recommended) or `pip` for Python dependency management

## Local setup
1) Create and activate a virtual environment:
```bash
python -m venv .venv
source .venv/bin/activate
```
2) Install dependencies (choose one):
```bash
# Using uv (preferred)
uv pip install -e .

# Using pip
pip install -e .
```
3) Add a `.env` file in the project root with the required credentials:
```bash
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SPOTIFY_REDIRECT_URI=http://localhost:8888/callback
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
- Provisions Kinesis (`SpotifyStream`), DynamoDB (`SpotifyEvents`), Lambdas, Firehoses (hot and cold) with Parquet conversion, Glue catalog, S3 buckets with lifecycle (cold → Glacier), IAM role/policy, and event source mapping.
- Update the `archive_file` sources in Terraform to point to `../src/processor/hot_path_function.py` and `../src/processor/cold_path_function.py` so the Lambda zips include the current handlers.
- Remember to destroy resources when finished (`terraform destroy`) to avoid ongoing cloud charges.

## Event contract
Example payload emitted by the producer and stored by the Lambda processor:
```json
{
  "event_type": "track_change",
  "track_name": "My Song",
  "status": "COMPLETED",
  "duration_listened": 142,
  "timestamp": 1731100000,
  "user_id": "spotify_user_id",
  "processing_path": "hot"
}
```

## How the processor works
- Hot path: Lambda (`hot_path_function`) is triggered by Kinesis batches, decodes records, filters for `processing_path == "hot"`, applies business rules, and writes to DynamoDB via the `DYNAMODB_TABLE` env var.
- Cold/archival paths: Two Firehoses source the same Kinesis stream, invoke `cold_path_function` with `PROCESSING_PATH` env (`hot`/`cold`) to filter/flatten and emit Parquet to S3, partitioned by `user_id` with Glue schema for downstream analytics. Cold bucket transitions to Glacier via lifecycle.


## This project is under active development! So please check back for updates and improvements.
