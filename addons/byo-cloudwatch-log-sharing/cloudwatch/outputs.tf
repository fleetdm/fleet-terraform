output "subscription_filter_name" {
  description = "Created CloudWatch Logs subscription filter name."
  value       = aws_cloudwatch_log_subscription_filter.fleet_log_group.name
}

output "subscription_filter_log_group_name" {
  description = "CloudWatch Logs log group name where the subscription filter is configured."
  value       = aws_cloudwatch_log_subscription_filter.fleet_log_group.log_group_name
}

output "subscription_filter_destination_arn" {
  description = "CloudWatch Logs destination ARN used by the subscription filter."
  value       = aws_cloudwatch_log_subscription_filter.fleet_log_group.destination_arn
}
