output "subscription_filter" {
  description = "CloudWatch Logs subscription filter details."
  value = {
    name            = aws_cloudwatch_log_subscription_filter.fleet_log_group.name
    log_group_name  = aws_cloudwatch_log_subscription_filter.fleet_log_group.log_group_name
    destination_arn = aws_cloudwatch_log_subscription_filter.fleet_log_group.destination_arn
  }
}
