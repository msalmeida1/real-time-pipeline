provider "aws" {
  region = "us-east-1"
}

variable "spotify_secret_arn" {
  type        = string
  description = "ARN of the Spotify secret in Secrets Manager"
}

module "storage" {
  source = "./modules/storage"
}

module "streaming" {
  source = "./modules/streaming"
}

module "cold_path_musical_profile_function" {
  source = "./modules/processor/cold_path/musical_profile_function"

  spotify_secret_arn  = var.spotify_secret_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
  kinesis_stream_arn  = module.streaming.stream_arn
}

module "cold_path_processor" {
  source = "./modules/processor/cold_path/processor_function"
}

module "firehose" {
  source = "./modules/firehose"

  kinesis_stream_arn           = module.streaming.stream_arn
  cold_path_bucket_arn         = module.storage.cold_bucket_arn
  transform_cold_path_lambda_arn = module.cold_path_processor.cold_path_processor_lambda_arn
}

module "api_gateway" {
  source = "./modules/api_gateway"

  kinesis_stream_arn  = module.streaming.stream_arn
  kinesis_stream_name = module.streaming.stream_name
}

resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn  = module.streaming.stream_arn
  function_name     = module.cold_path_musical_profile_function.cold_path_musical_profile_lambda_arn
  starting_position = "TRIM_HORIZON"
  batch_size        = 30
  enabled           = true
}

output "api_gateway_url" {
  value = module.api_gateway.api_gateway_url
}
