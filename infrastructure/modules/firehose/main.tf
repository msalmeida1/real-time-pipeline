variable "kinesis_stream_arn" {
  type        = string
  description = "Kinesis stream ARN Firehose reads from"
}

variable "cold_bucket_arn" {
  type        = string
  description = "S3 bucket ARN for cold events"
}

variable "hot_bucket_arn" {
  type        = string
  description = "S3 bucket ARN for hot events"
}

variable "glue_database_name" {
  type        = string
  description = "Glue database name for schema configuration"
}

variable "glue_cold_table_name" {
  type        = string
  description = "Glue table name for cold events"
}

variable "glue_hot_table_name" {
  type        = string
  description = "Glue table name for hot events"
}

variable "transform_cold_lambda_arn" {
  type        = string
  description = "Lambda ARN for cold path transformation"
}

variable "transform_cold_lambda_name" {
  type        = string
  description = "Lambda name for cold path transformation"
}

variable "transform_hot_lambda_arn" {
  type        = string
  description = "Lambda ARN for hot path transformation"
}

variable "transform_hot_lambda_name" {
  type        = string
  description = "Lambda name for hot path transformation"
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
          var.cold_bucket_arn,
          "${var.cold_bucket_arn}/*",
          var.hot_bucket_arn,
          "${var.hot_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunctionConfiguration"
        ]
        Resource = [
          var.transform_cold_lambda_arn,
          "${var.transform_cold_lambda_arn}:*",
          var.transform_hot_lambda_arn,
          "${var.transform_hot_lambda_arn}:*"
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

resource "aws_kinesis_firehose_delivery_stream" "cold_events" {
  name        = "spotify-cold-events"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = var.kinesis_stream_arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = var.cold_bucket_arn
    prefix              = "cold/user_id=!{partitionKeyFromLambda:user_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
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
          parameter_value = var.transform_cold_lambda_arn
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
        role_arn      = aws_iam_role.firehose_role.arn
        database_name = var.glue_database_name
        table_name    = var.glue_cold_table_name
      }
    }
  }
}

resource "aws_lambda_permission" "allow_firehose_invoke_cold" {
  statement_id  = "AllowExecutionFromFirehose"
  action        = "lambda:InvokeFunction"
  function_name = var.transform_cold_lambda_name
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.cold_events.arn
}

resource "aws_kinesis_firehose_delivery_stream" "hot_events" {
  name        = "spotify-hot-events"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = var.kinesis_stream_arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = var.hot_bucket_arn
    prefix              = "hot/user_id=!{partitionKeyFromLambda:user_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
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
          parameter_value = var.transform_hot_lambda_arn
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
        role_arn      = aws_iam_role.firehose_role.arn
        database_name = var.glue_database_name
        table_name    = var.glue_hot_table_name
      }
    }
  }
}

resource "aws_lambda_permission" "allow_firehose_invoke_hot" {
  statement_id  = "AllowExecutionFromFirehoseHot"
  action        = "lambda:InvokeFunction"
  function_name = var.transform_hot_lambda_name
  principal     = "firehose.amazonaws.com"
  source_arn    = aws_kinesis_firehose_delivery_stream.hot_events.arn
}
