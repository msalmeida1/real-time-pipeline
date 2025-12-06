output "cold_path_lambda_arn" {
  value = aws_lambda_function.firehose_transform_cold_path_cold_data.arn
}

output "cold_path_lambda_name" {
  value = aws_lambda_function.firehose_transform_cold_path_cold_data.function_name
}

output "hot_path_lambda_arn" {
  value = aws_lambda_function.firehose_transform_cold_path_hot_data.arn
}

output "hot_path_lambda_name" {
  value = aws_lambda_function.firehose_transform_cold_path_hot_data.function_name
}

output "role_arn" {
  value = aws_iam_role.firehose_transform_role.arn
}
