variable "kinesis_stream_arn" {
  type        = string
  description = "Kinesis stream ARN the API Gateway writes to"
}

variable "kinesis_stream_name" {
  type        = string
  description = "Kinesis stream name the API Gateway writes to"
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

data "aws_region" "current" {}

resource "aws_api_gateway_rest_api" "spotify_api" {
  name        = "SpotifyEventsAPI"
  description = "API Gateway for Spotify Events"
  tags        = local.tags
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
        Effect   = "Allow"
        Action   = "kinesis:PutRecord"
        Resource = var.kinesis_stream_arn
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
  "StreamName": "${var.kinesis_stream_name}",
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
