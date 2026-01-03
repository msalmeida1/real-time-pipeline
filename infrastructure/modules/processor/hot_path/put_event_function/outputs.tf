output "lambda_arn" {
  value = aws_lambda_function.hot_path_put_event_function.arn
}

output "lambda_name" {
  value = aws_lambda_function.hot_path_put_event_function.function_name
}

output "role_arn" {
  value = aws_iam_role.lambda_processor_role.arn
}
