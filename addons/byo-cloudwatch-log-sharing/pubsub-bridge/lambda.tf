locals {
  bridge_lambda_binary_path = "${path.module}/lambda/bootstrap"
  bridge_lambda_go_arch     = var.lambda.architecture == "arm64" ? "arm64" : "amd64"
}

resource "null_resource" "bridge_build" {
  triggers = {
    main_go_changes = filesha256("${path.module}/lambda/main.go")
    go_mod_changes  = filesha256("${path.module}/lambda/go.mod")
    go_sum_changes  = fileexists("${path.module}/lambda/go.sum") ? filesha256("${path.module}/lambda/go.sum") : ""
    go_arch         = local.bridge_lambda_go_arch
    binary_exists   = fileexists(local.bridge_lambda_binary_path) ? true : timestamp()
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/lambda"
    command     = <<-EOT
      go mod download
      CGO_ENABLED=0 GOOS=linux GOARCH=${local.bridge_lambda_go_arch} go build -tags lambda.norpc -o bootstrap main.go
    EOT
  }
}

data "archive_file" "bridge" {
  depends_on  = [null_resource.bridge_build]
  type        = "zip"
  output_path = "${path.module}/lambda/.pubsub-bridge.zip"
  source_file = local.bridge_lambda_binary_path
}

resource "aws_cloudwatch_log_group" "bridge" {
  name              = local.lambda_log_group_name
  retention_in_days = var.lambda.log_retention_in_days
  tags              = var.tags
}

resource "aws_lambda_function" "bridge" {
  function_name = var.lambda.function_name
  role          = aws_iam_role.bridge.arn
  runtime       = var.lambda.runtime
  handler       = "bootstrap"
  architectures = [var.lambda.architecture]
  timeout       = var.lambda.timeout
  memory_size   = var.lambda.memory_size

  reserved_concurrent_executions = var.lambda.reserved_concurrent_executions == -1 ? null : var.lambda.reserved_concurrent_executions

  filename         = data.archive_file.bridge.output_path
  source_code_hash = data.archive_file.bridge.output_base64sha256

  environment {
    variables = {
      GCP_PUBSUB_PROJECT_ID      = var.gcp_pubsub.project_id
      GCP_PUBSUB_TOPIC_ID        = var.gcp_pubsub.topic_id
      GCP_CREDENTIALS_SECRET_ARN = var.gcp_pubsub.credentials_secret_arn
      PUBSUB_BATCH_SIZE          = tostring(var.lambda.batch_size)
    }
  }

  tags = var.tags

  depends_on = [
    aws_cloudwatch_log_group.bridge,
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_iam_role_policy_attachment.bridge,
  ]
}

resource "aws_lambda_permission" "allow_cloudwatch_logs" {
  statement_id   = "AllowExecutionFromCloudWatchLogs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.bridge.function_name
  principal      = "logs.${data.aws_region.current.region}.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = local.source_log_group_subscription_arn
}
