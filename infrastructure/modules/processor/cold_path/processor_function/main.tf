variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }

  build_dir        = "${path.module}/build"
  cold_path_source = "${path.root}/../src/processor/cold_path_processor_function.py"
  packaged_zip     = "${local.build_dir}/cold_path_processor_function.zip"
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

resource "aws_lambda_function" "cold_path_processor_lambda_arn" {
  filename         = data.archive_file.firehose_transform_zip.output_path
  function_name    = "cold_path_processor_function"
  role             = aws_iam_role.firehose_transform_role.arn
  handler          = "cold_path_processor_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.firehose_transform_zip.output_base64sha256
  timeout          = 60
}

resource "aws_cloudwatch_log_group" "cold_path_processor_logs" {
  name              = "/aws/lambda/cold_path_processor_function"
  retention_in_days = 1
}