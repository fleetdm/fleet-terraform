locals {
  alerting_ok_actions = var.alerting.enable_ok_notifications ? var.alerting.sns_topic_arns : []
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.alerting.enabled ? 1 : 0

  alarm_name          = "${var.lambda.function_name}-errors"
  alarm_description   = "Fleet CloudWatch Pub/Sub bridge Lambda has invocation errors. Notifications fire on alarm-state transitions to avoid alert spam."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alerting.evaluation_periods
  datapoints_to_alarm = var.alerting.datapoints_to_alarm
  threshold           = var.alerting.lambda_errors_threshold
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  period              = var.alerting.period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.bridge.function_name
  }

  alarm_actions             = var.alerting.sns_topic_arns
  ok_actions                = local.alerting_ok_actions
  insufficient_data_actions = []

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  count = var.alerting.enabled && var.dlq.enabled ? 1 : 0

  alarm_name          = "${local.dlq_queue_name}-visible-messages"
  alarm_description   = "Fleet CloudWatch Pub/Sub bridge DLQ has visible messages pending reprocessing. Notifications fire on alarm-state transitions to avoid alert spam."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alerting.evaluation_periods
  datapoints_to_alarm = var.alerting.datapoints_to_alarm
  threshold           = var.alerting.dlq_visible_messages_threshold
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  period              = var.alerting.period_seconds
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[0].name
  }

  alarm_actions             = var.alerting.sns_topic_arns
  ok_actions                = local.alerting_ok_actions
  insufficient_data_actions = []

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "replayer_errors" {
  count = var.alerting.enabled && local.replayer_enabled ? 1 : 0

  alarm_name          = "${local.replayer_function_name}-errors"
  alarm_description   = "Fleet CloudWatch Pub/Sub bridge replayer Lambda has invocation errors. Notifications fire on alarm-state transitions to avoid alert spam."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alerting.evaluation_periods
  datapoints_to_alarm = var.alerting.datapoints_to_alarm
  threshold           = var.alerting.lambda_errors_threshold
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  period              = var.alerting.period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.replayer[0].function_name
  }

  alarm_actions             = var.alerting.sns_topic_arns
  ok_actions                = local.alerting_ok_actions
  insufficient_data_actions = []

  tags = var.tags
}
