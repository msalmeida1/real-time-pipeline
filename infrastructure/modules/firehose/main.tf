variable "kinesis_stream_arn" {
  type        = string
  description = "Kinesis stream ARN Firehose reads from"
}

variable "cold_path_bucket_arn" {
  type        = string
  description = "S3 bucket ARN for cold path"
}

variable "transform_cold_path_lambda_arn" {
  type        = string
  description = "Lambda ARN for cold path transformation"
}

variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }
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
        Resource = var.kinesis_stream_arn
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
          var.cold_path_bucket_arn,
          "${var.cold_path_bucket_arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunctionConfiguration"
        ]
        Resource = [
          var.transform_cold_path_lambda_arn,
          "${var.transform_cold_path_lambda_arn}:*"
        ]
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

resource "aws_kinesis_firehose_delivery_stream" "cold_path" {
  name        = "spotify-cold-path"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = var.kinesis_stream_arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = var.cold_path_bucket_arn
    prefix              = "!{partitionKeyFromLambda:status}/!{partitionKeyFromLambda:user_id}/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/"
    error_output_prefix = "firehose-failures/cold/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"
    buffering_interval  = 300
    buffering_size      = 64
    compression_format  = "UNCOMPRESSED"
    s3_backup_mode      = "Disabled"
    file_extension      = ".jsonl"

    dynamic_partitioning_configuration {
      enabled = true
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/cold-path-events"
      log_stream_name = "S3Delivery"
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = var.transform_cold_path_lambda_arn
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
  }
}

resource "aws_lambda_permission" "allow_firehose_invoke_cold" {
  statement_id  = "AllowExecutionFromFirehose"
  action        = "lambda:InvokeFunction"
  function_name = var.transform_cold_path_lambda_arn
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.cold_path.arn
}
