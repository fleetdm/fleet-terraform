output "cron_monitoring_lambda_arn" {
  value = try(aws_lambda_function.cron_monitoring[0].arn, null)
}

output "cron_monitoring_lambda_role_arn" {
  value = try(aws_iam_role.cron_monitoring_lambda[0].arn, null)
}
