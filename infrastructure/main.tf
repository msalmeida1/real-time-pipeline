provider "aws" {
  region = "us-east-1"
}

variable "spotify_client_id" {
  type        = string
  description = "Spotify Client ID"
}

variable "spotify_client_secret" {
  type        = string
  description = "Spotify Client Secret"
  sensitive   = true
}

# Database
resource "aws_dynamodb_table" "user_musical_profile" {
  name         = "user_musical_profile"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
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
          "kinesis:ListStreams",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.music_stream.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.user_musical_profile.arn
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
          aws_lambda_function.firehose_transform_cold_path_cold_data.arn,
          "${aws_lambda_function.firehose_transform_cold_path_cold_data.arn}:*",
          aws_lambda_function.firehose_transform_cold_path_hot_data.arn,
          "${aws_lambda_function.firehose_transform_cold_path_hot_data.arn}:*"
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
resource "null_resource" "install_dependencies" {
  triggers = {
    requirements = filesha256("../src/processor/requirements.txt")
    source_code  = filesha256("../src/processor/hot_path_function.py")
  }

  provisioner "local-exec" {
    command = <<EOT
      rm -rf build/hot_path_function
      mkdir -p build/hot_path_function
      pip install -r ../src/processor/requirements.txt -t build/hot_path_function
      cp ../src/processor/hot_path_function.py build/hot_path_function/
    EOT
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "build/hot_path_function"
  output_path = "hot_path_function.zip"
  
  depends_on = [null_resource.install_dependencies]
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
      DYNAMODB_TABLE = aws_dynamodb_table.user_musical_profile.name
      SPOTIFY_CLIENT_ID     = var.spotify_client_id
      SPOTIFY_CLIENT_SECRET = var.spotify_client_secret
    }
  }
}

resource "aws_cloudwatch_log_group" "processor_logs" {
  name              = "/aws/lambda/hot_path_function"
  retention_in_days = 1
}

resource "aws_lambda_function" "firehose_transform_cold_path_cold_data" {
  filename         = "cold_path_function.zip"
  function_name    = "cold_path_cold_data_firehose_function"
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

resource "aws_cloudwatch_log_group" "cold_path_cold_data_logs" {
  name              = "/aws/lambda/cold_path_cold_data_firehose_function"
  retention_in_days = 1
}

resource "aws_lambda_function" "firehose_transform_cold_path_hot_data" {
  filename         = "cold_path_function.zip"
  function_name    = "cold_path_hot_data_firehose_function"
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
resource "aws_cloudwatch_log_group" "cold_path_hot_data_logs" {
  name              = "/aws/lambda/cold_path_hot_data_firehose_function"
  retention_in_days = 1
}

# Event Source Mapping
resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn  = aws_kinesis_stream.music_stream.arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "TRIM_HORIZON" 
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
    buffering_size      = 64
    compression_format  = "UNCOMPRESSED"

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
          parameter_value = aws_lambda_function.firehose_transform_cold_path_cold_data.arn
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
  function_name = aws_lambda_function.firehose_transform_cold_path_cold_data.function_name
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
    buffering_size      = 64
    compression_format  = "UNCOMPRESSED"

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
          parameter_value = aws_lambda_function.firehose_transform_cold_path_hot_data.arn
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
  function_name = aws_lambda_function.firehose_transform_cold_path_hot_data.function_name
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.hot_events.arn
}

# API Gateway
data "aws_region" "current" {}

resource "aws_api_gateway_rest_api" "spotify_api" {
  name        = "SpotifyEventsAPI"
  description = "API Gateway for Spotify Events"
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.spotify_api.id
  parent_id   = aws_api_gateway_rest_api.spotify_api.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_method" "post_event" {
  rest_api_id   = aws_api_gateway_rest_api.spotify_api.id
  resource_id   = aws_api_gateway_resource.events.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_iam_role" "api_gateway_kinesis_role" {
  name = "api_gateway_kinesis_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "api_gateway_kinesis_policy" {
  name = "api_gateway_kinesis_policy"
  role = aws_iam_role.api_gateway_kinesis_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "kinesis:PutRecord"
        Resource = aws_kinesis_stream.music_stream.arn
      }
    ]
  })
}

resource "aws_api_gateway_integration" "kinesis_integration" {
  rest_api_id             = aws_api_gateway_rest_api.spotify_api.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_event.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:kinesis:action/PutRecord"
  credentials             = aws_iam_role.api_gateway_kinesis_role.arn

  request_templates = {
    "application/json" = <<EOF
{
  "StreamName": "${aws_kinesis_stream.music_stream.name}",
  "Data": "$util.base64Encode($input.json('$'))",
  "PartitionKey": "$input.path('$.user_id')"
}
EOF
  }
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.spotify_api.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_event.http_method
  status_code = "200"
  
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "integration_response_200" {
  rest_api_id = aws_api_gateway_rest_api.spotify_api.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_event.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code
  
  depends_on = [aws_api_gateway_integration.kinesis_integration]
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.spotify_api.id

  depends_on = [
    aws_api_gateway_integration.kinesis_integration
  ]
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_method.post_event.id,
      aws_api_gateway_integration.kinesis_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.spotify_api.id
  stage_name    = "dev"
}

output "api_gateway_url" {
  value = "${aws_api_gateway_stage.dev.invoke_url}/events"
}
