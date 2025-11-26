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

resource "aws_s3_bucket" "cold_events" {
  bucket_prefix = "spotify-cold-events-"
  force_destroy = true

  tags = {
    Project = "SpotifyAnalytics"
  }
}

resource "aws_s3_bucket" "hot_events" {
  bucket_prefix = "spotify-hot-events-"
  force_destroy = true

  tags = {
    Project = "SpotifyAnalytics"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cold_events" {
  bucket = aws_s3_bucket.cold_events.id

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_glue_catalog_database" "spotify" {
  name = "spotify_events"
}

resource "aws_glue_catalog_table" "spotify_hot_events" {
  name          = "spotify_hot_events"
  database_name = aws_glue_catalog_database.spotify.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://dummy-placeholder/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "event_type"
      type = "string"
    }
    columns {
      name = "track_id"
      type = "string"
    }
    columns {
      name = "track_name"
      type = "string"
    }
    columns {
      name = "status"
      type = "string"
    }
    columns {
      name = "processing_path"
      type = "string"
    }
    columns {
      name = "duration_listened"
      type = "int"
    }
    columns {
      name = "timestamp"
      type = "bigint"
    }
    columns {
      name = "user_id"
      type = "string"
    }
  }
}

resource "aws_glue_catalog_table" "spotify_cold_events" {
  name          = "spotify_cold_events"
  database_name = aws_glue_catalog_database.spotify.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://dummy-placeholder/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "is_playing"
      type = "boolean"
    }
    columns {
      name = "timestamp"
      type = "bigint"
    }
    columns {
      name = "progress_ms"
      type = "int"
    }
    columns {
      name = "item_album_artists"
      type = "string"
    }
    columns {
      name = "item_album_id"
      type = "string"
    }
    columns {
      name = "item_album_name"
      type = "string"
    }
    columns {
      name = "item_album_release_date"
      type = "string"
    }
    columns {
      name = "item_album_total_tracks"
      type = "int"
    }
    columns {
      name = "item_artists"
      type = "string"
    }
    columns {
      name = "item_disc_number"
      type = "int"
    }
    columns {
      name = "item_duration_ms"
      type = "int"
    }
    columns {
      name = "item_explicit"
      type = "boolean"
    }
    columns {
      name = "item_external_ids_isrc"
      type = "string"
    }
    columns {
      name = "item_id"
      type = "string"
    }
    columns {
      name = "item_name"
      type = "string"
    }
    columns {
      name = "item_popularity"
      type = "int"
    }
    columns {
      name = "item_track_number"
      type = "int"
    }
    columns {
      name = "item_type"
      type = "string"
    }
    columns {
      name = "processing_path"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
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

resource "aws_iam_role" "firehose_transform_role" {
  name = "spotify_firehose_transform_role"

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

resource "aws_iam_role_policy" "firehose_transform_policy" {
  name = "spotify_firehose_transform_policy"
  role = aws_iam_role.firehose_transform_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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

resource "aws_iam_role" "firehose_role" {
  name = "spotify_firehose_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "firehose_policy" {
  name = "spotify_firehose_policy"
  role = aws_iam_role.firehose_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.music_stream.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.cold_events.arn,
          "${aws_s3_bucket.cold_events.arn}/*",
          aws_s3_bucket.hot_events.arn,
          "${aws_s3_bucket.hot_events.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunctionConfiguration"
        ]
        Resource = [
          aws_lambda_function.firehose_transform.arn,
          "${aws_lambda_function.firehose_transform.arn}:*",
          aws_lambda_function.firehose_transform_hot.arn,
          "${aws_lambda_function.firehose_transform_hot.arn}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTableVersion",
          "glue:GetTableVersions",
          "glue:GetSchemaByDefinition",
          "glue:GetDatabase",
          "glue:GetDatabases"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda Function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../src/processor/hot_path_function.py"
  output_path = "hot_path_function.zip"
}

data "archive_file" "firehose_transform_zip" {
  type        = "zip"
  source_file = "../src/processor/cold_path_function.py"
  output_path = "cold_path_function.zip"
}

resource "aws_lambda_function" "processor" {
  filename      = "hot_path_function.zip"
  function_name = "hot_path_function"
  role          = aws_iam_role.lambda_processor_role.arn
  handler       = "hot_path_function.lambda_handler"
  runtime       = "python3.9"

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.spotify_events.name
    }
  }
}

resource "aws_lambda_function" "firehose_transform_cold" {
  filename         = "cold_path_function.zip"
  function_name    = "cold_path_firehose_function"
  role             = aws_iam_role.firehose_transform_role.arn
  handler          = "cold_path_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.firehose_transform_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      PROCESSING_PATH = "cold"
    }
  }
}

resource "aws_lambda_function" "firehose_transform_hot" {
  filename         = "cold_path_function.zip"
  function_name    = "hot_path_firehose_function"
  role             = aws_iam_role.firehose_transform_role.arn
  handler          = "cold_path_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.firehose_transform_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      PROCESSING_PATH = "hot"
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

resource "aws_kinesis_firehose_delivery_stream" "cold_events" {
  name        = "spotify-cold-events"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.music_stream.arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.cold_events.arn
    prefix     = "cold/user_id=!{partitionKeyFromLambda:user_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "firehose-failures/cold/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"
    buffering_interval  = 300
    buffering_size      = 5
    compression_format  = "SNAPPY"

    dynamic_partitioning_configuration {
      enabled = true
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/cold-events"
      log_stream_name = "S3Delivery"
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.firehose_transform.arn
        }
        parameters {
          parameter_name  = "NumberOfRetries"
          parameter_value = "3"
        }
        parameters {
          parameter_name  = "RoleArn"
          parameter_value = aws_iam_role.firehose_role.arn
        }
      }
    }

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }

      schema_configuration {
        role_arn       = aws_iam_role.firehose_role.arn
        database_name  = aws_glue_catalog_database.spotify.name
        table_name     = aws_glue_catalog_table.spotify_cold_events.name
      }
    }
  }
}

resource "aws_lambda_permission" "allow_firehose_invoke" {
  statement_id  = "AllowExecutionFromFirehose"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.firehose_transform_cold.function_name
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.cold_events.arn
}

resource "aws_kinesis_firehose_delivery_stream" "hot_events" {
  name        = "spotify-hot-events"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.music_stream.arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.hot_events.arn
    prefix     = "hot/user_id=!{partitionKeyFromLambda:user_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "firehose-failures/hot/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"
    buffering_interval  = 300
    buffering_size      = 5
    compression_format  = "SNAPPY"

    dynamic_partitioning_configuration {
      enabled = true
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/hot-events"
      log_stream_name = "S3Delivery"
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.firehose_transform_hot.arn
        }
        parameters {
          parameter_name  = "NumberOfRetries"
          parameter_value = "3"
        }
        parameters {
          parameter_name  = "RoleArn"
          parameter_value = aws_iam_role.firehose_role.arn
        }
      }
    }

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }

      schema_configuration {
        role_arn       = aws_iam_role.firehose_role.arn
        database_name  = aws_glue_catalog_database.spotify.name
        table_name     = aws_glue_catalog_table.spotify_hot_events.name
      }
    }
  }
}

resource "aws_lambda_permission" "allow_firehose_invoke_hot" {
  statement_id  = "AllowExecutionFromFirehoseHot"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.firehose_transform_hot.function_name
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.hot_events.arn
}
