provider "aws" {
  region = "us-east-1"
}

module "storage" {
  source = "./modules/storage"
}

module "streaming" {
  source = "./modules/streaming"
}

module "lambda_processor" {
  source = "./modules/lambda_processor"

  spotify_secret_arn  = "arn:aws:secretsmanager:us-east-1:655916713824:secret:spotify_secret-yRYXPq"
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
  kinesis_stream_arn  = module.streaming.stream_arn
}

module "lambda_firehose_transform" {
  source = "./modules/lambda_firehose_transform"
}

module "firehose" {
  source = "./modules/firehose"

  kinesis_stream_arn         = module.streaming.stream_arn
  cold_bucket_arn            = module.storage.cold_bucket_arn
  hot_bucket_arn             = module.storage.hot_bucket_arn
  glue_database_name         = module.storage.glue_database_name
  glue_cold_table_name       = module.storage.glue_cold_table_name
  glue_hot_table_name        = module.storage.glue_hot_table_name
  transform_cold_lambda_arn  = module.lambda_firehose_transform.cold_path_lambda_arn
  transform_cold_lambda_name = module.lambda_firehose_transform.cold_path_lambda_name
  transform_hot_lambda_arn   = module.lambda_firehose_transform.hot_path_lambda_arn
  transform_hot_lambda_name  = module.lambda_firehose_transform.hot_path_lambda_name
}

module "api_gateway" {
  source = "./modules/api_gateway"

  kinesis_stream_arn  = module.streaming.stream_arn
  kinesis_stream_name = module.streaming.stream_name
}

resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn  = module.streaming.stream_arn
  function_name     = module.lambda_processor.lambda_arn
  starting_position = "TRIM_HORIZON"
  batch_size        = 30
  enabled           = true
}

output "api_gateway_url" {
  value = module.api_gateway.api_gateway_url
}
