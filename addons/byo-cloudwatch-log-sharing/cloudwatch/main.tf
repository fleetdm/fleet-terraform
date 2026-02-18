resource "aws_cloudwatch_log_subscription_filter" "fleet_log_group" {
  name            = var.subscription.filter_name
  log_group_name  = var.subscription.log_group_name
  filter_pattern  = var.subscription.filter_pattern
  destination_arn = var.subscription.destination_arn
  distribution    = var.subscription.destination_type == "kinesis" ? var.subscription.kinesis_distribution : null
}
