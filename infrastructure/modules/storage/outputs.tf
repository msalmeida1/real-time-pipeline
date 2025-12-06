output "dynamodb_table_name" {
  value = aws_dynamodb_table.user_musical_profile.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.user_musical_profile.arn
}

output "cold_bucket_arn" {
  value = aws_s3_bucket.cold_events.arn
}

output "cold_bucket_name" {
  value = aws_s3_bucket.cold_events.bucket
}

output "hot_bucket_arn" {
  value = aws_s3_bucket.hot_events.arn
}

output "hot_bucket_name" {
  value = aws_s3_bucket.hot_events.bucket
}

output "glue_database_name" {
  value = aws_glue_catalog_database.spotify.name
}

output "glue_cold_table_name" {
  value = aws_glue_catalog_table.spotify_cold_events.name
}

output "glue_hot_table_name" {
  value = aws_glue_catalog_table.spotify_hot_events.name
}
