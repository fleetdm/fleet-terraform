locals {
  replayer_lambda_binary_path = "${path.module}/lambda/replayer/bootstrap"
}

resource "null_resource" "replayer_build" {
  count = local.replayer_enabled ? 1 : 0

  triggers = {
    main_go_changes = filesha256("${path.module}/lambda/replayer/main.go")
    go_mod_changes  = filesha256("${path.module}/lambda/go.mod")
    go_sum_changes  = fileexists("${path.module}/lambda/go.sum") ? filesha256("${path.module}/lambda/go.sum") : ""
    go_arch         = local.replayer_go_arch
    binary_exists   = fileexists(local.replayer_lambda_binary_path) ? true : timestamp()
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/lambda"
    command     = <<-EOT
      go mod download
      CGO_ENABLED=0 GOOS=linux GOARCH=${local.replayer_go_arch} go build -tags lambda.norpc -o replayer/bootstrap ./replayer
    EOT
  }
}

data "archive_file" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  depends_on  = [null_resource.replayer_build[0]]
  type        = "zip"
  output_path = "${path.module}/lambda/.pubsub-bridge-replayer.zip"
  source_file = local.replayer_lambda_binary_path
}

resource "aws_cloudwatch_log_group" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  name              = local.replayer_log_group_name
  retention_in_days = var.replayer.log_retention_in_days
  tags              = var.tags
}

resource "aws_lambda_function" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  function_name = local.replayer_function_name
  role          = aws_iam_role.replayer[0].arn
  runtime       = local.replayer_runtime
  handler       = "bootstrap"
  architectures = [local.replayer_architecture]
  timeout       = var.replayer.timeout
  memory_size   = var.replayer.memory_size

  reserved_concurrent_executions = var.replayer.reserved_concurrent_executions == -1 ? null : var.replayer.reserved_concurrent_executions

  filename         = data.archive_file.replayer[0].output_path
  source_code_hash = data.archive_file.replayer[0].output_base64sha256

  environment {
    variables = {
      TARGET_BRIDGE_FUNCTION_NAME = aws_lambda_function.bridge.function_name
    }
  }

  tags = var.tags

  depends_on = [
    aws_cloudwatch_log_group.replayer,
    aws_iam_role_policy_attachment.replayer_lambda_basic_execution,
    aws_iam_role_policy_attachment.replayer,
  ]
}

resource "aws_lambda_event_source_mapping" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  event_source_arn                   = aws_sqs_queue.dlq[0].arn
  function_name                      = aws_lambda_function.replayer[0].arn
  batch_size                         = var.replayer.batch_size
  maximum_batching_window_in_seconds = var.replayer.maximum_batching_window_in_seconds
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true

  dynamic "scaling_config" {
    for_each = local.replayer_maximum_concurrency > 0 ? [1] : []

    content {
      maximum_concurrency = local.replayer_maximum_concurrency
    }
  }
}
