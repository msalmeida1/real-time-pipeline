output "dynamodb_table_name" {
  value = aws_dynamodb_table.user_musical_profile.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.user_musical_profile.arn
}

output "cold_bucket_arn" {
  value = aws_s3_bucket.cold_path.arn
}

output "cold_bucket_name" {
  value = aws_s3_bucket.cold_path.bucket
}
