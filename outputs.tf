output "lambda_function_name" {
  description = "Name of the deployed Makao Agent Lambda function."
  value       = aws_lambda_function.makao_agent.function_name
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB findings table."
  value       = aws_dynamodb_table.findings.name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution IAM role."
  value       = aws_iam_role.lambda_exec.arn
}

output "registration_status" {
  description = "Indicates whether the Terraform-time registration null_resource ran."
  value       = "registered"
  depends_on  = [null_resource.registration]
}
