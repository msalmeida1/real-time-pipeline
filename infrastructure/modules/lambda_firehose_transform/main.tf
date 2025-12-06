variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }

  build_dir        = "${path.module}/build"
  cold_path_source = "${path.module}/../../../src/processor/cold_path_function.py"
  packaged_zip     = "${local.build_dir}/cold_path_function.zip"
}

resource "null_resource" "prepare_build" {
  triggers = {
    build_dir = local.build_dir
  }

  provisioner "local-exec" {
    command = "mkdir -p ${local.build_dir}"
  }
}

data "archive_file" "firehose_transform_zip" {
  type        = "zip"
  source_file = local.cold_path_source
  output_path = local.packaged_zip

  depends_on = [null_resource.prepare_build]
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

resource "aws_lambda_function" "firehose_transform_cold_path_cold_data" {
  filename         = data.archive_file.firehose_transform_zip.output_path
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
  filename         = data.archive_file.firehose_transform_zip.output_path
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
