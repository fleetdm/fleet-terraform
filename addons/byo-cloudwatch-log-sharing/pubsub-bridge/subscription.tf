resource "aws_cloudwatch_log_subscription_filter" "bridge" {
  name            = var.subscription.filter_name
  log_group_name  = var.subscription.log_group_name
  filter_pattern  = var.subscription.filter_pattern
  destination_arn = aws_lambda_function.bridge.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_logs]
}
