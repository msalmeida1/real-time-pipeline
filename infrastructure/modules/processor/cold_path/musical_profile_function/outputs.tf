output "cold_path_musical_profile_lambda_arn" {
  value = aws_lambda_function.cold_path_musical_profile_lambda_arn.arn
}

output "cold_path_musical_profile_lambda_name" {
  value = aws_lambda_function.cold_path_musical_profile_lambda_arn.function_name
}

output "role_arn" {
  value = aws_iam_role.cold_path_musical_profile_lambda_role.arn
}
