provider "aws" {
  region = "us-east-1"
}

# Database
resource "aws_dynamodb_table" "spotify_events" {
  name         = "SpotifyEvents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "timestamp"

  attribute {
    name = "user_id"
    type = "S" 
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  tags = {
    Project = "SpotifyAnalytics"
  }
}

# Streaming Service
resource "aws_kinesis_stream" "music_stream" {
  name             = "SpotifyStream"
  shard_count      = 1
  retention_period = 24 # 24 horas

  shard_level_metrics = []

  tags = {
    Project = "SpotifyAnalytics"
  }
}

# IAM
resource "aws_iam_role" "lambda_processor_role" {
  name = "spotify_processor_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "spotify_processor_policy"
  role = aws_iam_role.lambda_processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListStreams"
        ]
        Resource = aws_kinesis_stream.music_stream.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.spotify_events.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda Function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../src/processor/function.py"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "processor" {
  filename      = "lambda_function.zip"
  function_name = "SpotifyStreamProcessor"
  role          = aws_iam_role.lambda_processor_role.arn
  handler       = "function.lambda_handler"
  runtime       = "python3.9"

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.spotify_events.name
    }
  }
}

# Event Source Mapping
resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn  = aws_kinesis_stream.music_stream.arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST" 
  batch_size        = 30       
  enabled           = true
}