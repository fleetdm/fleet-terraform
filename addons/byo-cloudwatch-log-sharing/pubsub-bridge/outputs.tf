output "lambda" {
  description = "Lambda bridge details."
  value = {
    arn            = aws_lambda_function.bridge.arn
    function_name  = aws_lambda_function.bridge.function_name
    role_arn       = aws_iam_role.bridge.arn
    log_group_name = aws_cloudwatch_log_group.bridge.name
  }
}

output "subscription_filter" {
  description = "CloudWatch Logs subscription filter details."
  value = {
    name            = aws_cloudwatch_log_subscription_filter.bridge.name
    log_group_name  = aws_cloudwatch_log_subscription_filter.bridge.log_group_name
    destination_arn = aws_cloudwatch_log_subscription_filter.bridge.destination_arn
  }
}

output "pubsub" {
  description = "Configured GCP Pub/Sub destination details."
  value = {
    project_id             = var.gcp_pubsub.project_id
    topic_id               = var.gcp_pubsub.topic_id
    credentials_secret_arn = var.gcp_pubsub.credentials_secret_arn
  }
}

output "dlq" {
  description = "Dead-letter queue configuration and resource details."
  value = {
    enabled                      = var.dlq.enabled
    queue_name                   = try(aws_sqs_queue.dlq[0].name, null)
    queue_arn                    = try(aws_sqs_queue.dlq[0].arn, null)
    queue_url                    = try(aws_sqs_queue.dlq[0].url, null)
    maximum_retry_attempts       = var.dlq.maximum_retry_attempts
    maximum_event_age_in_seconds = var.dlq.maximum_event_age_in_seconds
  }
}

output "alerting" {
  description = "CloudWatch alarm and notification resources for bridge health."
  value = {
    enabled                         = var.alerting.enabled
    sns_topic_arns                  = var.alerting.sns_topic_arns
    lambda_errors_alarm_name        = try(aws_cloudwatch_metric_alarm.lambda_errors[0].alarm_name, null)
    lambda_errors_alarm_arn         = try(aws_cloudwatch_metric_alarm.lambda_errors[0].arn, null)
    replayer_errors_alarm_name      = try(aws_cloudwatch_metric_alarm.replayer_errors[0].alarm_name, null)
    replayer_errors_alarm_arn       = try(aws_cloudwatch_metric_alarm.replayer_errors[0].arn, null)
    dlq_visible_messages_alarm_name = try(aws_cloudwatch_metric_alarm.dlq_visible_messages[0].alarm_name, null)
    dlq_visible_messages_alarm_arn  = try(aws_cloudwatch_metric_alarm.dlq_visible_messages[0].arn, null)
  }
}

output "replayer" {
  description = "DLQ replayer Lambda and event source mapping details."
  value = {
    enabled                         = local.replayer_enabled
    function_name                   = try(aws_lambda_function.replayer[0].function_name, null)
    function_arn                    = try(aws_lambda_function.replayer[0].arn, null)
    role_arn                        = try(aws_iam_role.replayer[0].arn, null)
    event_source_mapping_uuid       = try(aws_lambda_event_source_mapping.replayer[0].uuid, null)
    batch_size                      = var.replayer.batch_size
    maximum_batching_window_seconds = var.replayer.maximum_batching_window_in_seconds
    maximum_concurrency             = var.replayer.maximum_concurrency
  }
}
