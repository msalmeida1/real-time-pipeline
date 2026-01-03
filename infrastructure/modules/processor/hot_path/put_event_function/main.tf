variable "spotify_secret_arn" {
  type        = string
  description = "ARN do secret do Spotify no Secrets Manager"
}

variable "dynamodb_table_name" {
  type        = string
  description = "DynamoDB table name for user profiles"
}

variable "dynamodb_table_arn" {
  type        = string
  description = "DynamoDB table ARN for IAM policy scoping"
}

variable "kinesis_stream_arn" {
  type        = string
  description = "Kinesis stream ARN for IAM policy scoping"
}

variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }

  build_dir       = "${path.module}/build"
  requirements    = "${path.root}/../src/processor/requirements.txt"
  hot_path_source = "${path.root}/../src/processor/hot_path_put_event_function.py"
}

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
        Resource = var.kinesis_stream_arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.spotify_secret_arn
      }
    ]
  })
}

resource "null_resource" "install_dependencies" {
  triggers = {
    requirements = filesha256(local.requirements)
    source_code  = filesha256(local.hot_path_source)
  }

  provisioner "local-exec" {
    command = <<EOT
      rm -rf ${local.build_dir}/hot_path_put_event_function
      mkdir -p ${local.build_dir}/hot_path_put_event_function
      pip install -r ${local.requirements} -t ${local.build_dir}/hot_path_put_event_function
      cp ${local.hot_path_source} ${local.build_dir}/hot_path_put_event_function/
    EOT
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${local.build_dir}/hot_path_put_event_function"
  output_path = "${local.build_dir}/hot_path_put_event_function.zip"

  depends_on = [null_resource.install_dependencies]
}

resource "aws_lambda_function" "hot_path_put_event_function" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "hot_path_put_event_function"
  role          = aws_iam_role.lambda_processor_role.arn
  handler       = "hot_path_put_event_function.lambda_handler"
  runtime       = "python3.12"

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE    = var.dynamodb_table_name
      SPOTIFY_SECRET_ID = var.spotify_secret_arn
    }
  }
}

resource "aws_cloudwatch_log_group" "processor_logs" {
  name              = "/aws/lambda/hot_path_put_event_function"
  retention_in_days = 1
}
