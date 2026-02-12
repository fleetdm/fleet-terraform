data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  lambda_log_group_name = "/aws/lambda/${var.lambda.function_name}"

  source_log_group_arn = coalesce(
    var.subscription.log_group_arn,
    "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.subscription.log_group_name}"
  )

  source_log_group_subscription_arn = endswith(local.source_log_group_arn, ":*") ? local.source_log_group_arn : "${local.source_log_group_arn}:*"

  lambda_policy_name = coalesce(
    var.lambda.policy_name,
    "${var.lambda.role_name}-policy"
  )

  dlq_kms_key_arn = startswith(var.dlq.kms_master_key_id, "alias/") ? "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.dlq.kms_master_key_id}" : var.dlq.kms_master_key_id

  replayer_function_name       = coalesce(var.replayer.function_name, "${var.lambda.function_name}-replayer")
  replayer_role_name           = coalesce(var.replayer.role_name, "${local.replayer_function_name}-role")
  replayer_policy_name         = coalesce(var.replayer.policy_name, "${local.replayer_role_name}-policy")
  replayer_runtime             = coalesce(var.replayer.runtime, var.lambda.runtime)
  replayer_architecture        = coalesce(var.replayer.architecture, var.lambda.architecture)
  replayer_log_group_name      = "/aws/lambda/${local.replayer_function_name}"
  replayer_enabled             = var.replayer.enabled && var.dlq.enabled
  replayer_go_arch             = local.replayer_architecture == "arm64" ? "arm64" : "amd64"
  replayer_maximum_concurrency = var.replayer.maximum_concurrency
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bridge" {
  name               = var.lambda.role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.bridge.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "bridge" {
  statement {
    sid    = "GetPubSubCredentialsSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]

    resources = [var.gcp_pubsub.credentials_secret_arn]
  }

  dynamic "statement" {
    for_each = var.dlq.enabled ? [1] : []

    content {
      sid    = "SendToAsyncFailureDLQ"
      effect = "Allow"

      actions = [
        "sqs:SendMessage",
      ]

      resources = [aws_sqs_queue.dlq[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.gcp_pubsub.secret_kms_key_arn != "" ? [1] : []

    content {
      sid    = "DecryptPubSubCredentialsSecretKey"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
      ]

      resources = [var.gcp_pubsub.secret_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.dlq.enabled && var.dlq.kms_master_key_id != "" ? [1] : []

    content {
      sid    = "EncryptDLQMessages"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]

      resources = [local.dlq_kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "bridge" {
  name   = local.lambda_policy_name
  policy = data.aws_iam_policy_document.bridge.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "bridge" {
  role       = aws_iam_role.bridge.name
  policy_arn = aws_iam_policy.bridge.arn
}

resource "aws_iam_role" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  name               = local.replayer_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "replayer_lambda_basic_execution" {
  count = local.replayer_enabled ? 1 : 0

  role       = aws_iam_role.replayer[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  statement {
    sid    = "InvokeBridgeLambda"
    effect = "Allow"

    actions = [
      "lambda:InvokeFunction",
    ]

    resources = [aws_lambda_function.bridge.arn]
  }

  statement {
    sid    = "ReadFromDLQ"
    effect = "Allow"

    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]

    resources = [aws_sqs_queue.dlq[0].arn]
  }

  dynamic "statement" {
    for_each = var.dlq.kms_master_key_id != "" ? [1] : []

    content {
      sid    = "DecryptDLQMessages"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
      ]

      resources = [local.dlq_kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  name   = local.replayer_policy_name
  policy = data.aws_iam_policy_document.replayer[0].json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "replayer" {
  count = local.replayer_enabled ? 1 : 0

  role       = aws_iam_role.replayer[0].name
  policy_arn = aws_iam_policy.replayer[0].arn
}
