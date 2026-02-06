locals {
  dlq_queue_name = coalesce(var.dlq.queue_name, "${var.lambda.function_name}-dlq")
}

resource "aws_sqs_queue" "dlq" {
  count = var.dlq.enabled ? 1 : 0

  name                       = local.dlq_queue_name
  message_retention_seconds  = var.dlq.message_retention_seconds
  visibility_timeout_seconds = var.dlq.visibility_timeout_seconds

  kms_master_key_id       = var.dlq.kms_master_key_id != "" ? var.dlq.kms_master_key_id : null
  sqs_managed_sse_enabled = var.dlq.kms_master_key_id == "" ? var.dlq.sqs_managed_sse_enabled : null

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "bridge" {
  count = var.dlq.enabled ? 1 : 0

  function_name                = aws_lambda_function.bridge.function_name
  maximum_retry_attempts       = var.dlq.maximum_retry_attempts
  maximum_event_age_in_seconds = var.dlq.maximum_event_age_in_seconds

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq[0].arn
    }
  }
}
