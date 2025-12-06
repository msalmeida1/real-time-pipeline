output "lambda_arn" {
  value = aws_lambda_function.processor.arn
}

output "lambda_name" {
  value = aws_lambda_function.processor.function_name
}

output "role_arn" {
  value = aws_iam_role.lambda_processor_role.arn
}
