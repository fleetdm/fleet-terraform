data "aws_region" "destination" {
  provider = aws.destination
}

data "aws_region" "target" {
  provider = aws.target
}

data "aws_caller_identity" "destination" {
  provider = aws.destination
}

data "aws_caller_identity" "target" {
  provider = aws.target
}

data "aws_partition" "destination" {
  provider = aws.destination
}

locals {
  allowed_source_accounts = distinct(concat(var.source_account_ids, [data.aws_caller_identity.destination.account_id]))

  allowed_source_arns = [
    for account_id in local.allowed_source_accounts :
    "arn:${data.aws_partition.destination.partition}:logs:${data.aws_region.destination.region}:${account_id}:*"
  ]
}

resource "aws_cloudwatch_log_destination" "destination" {
  provider   = aws.destination
  name       = var.cloudwatch_destination.name
  role_arn   = aws_iam_role.destination.arn
  target_arn = aws_kinesis_firehose_delivery_stream.destination.arn
}

data "aws_iam_policy_document" "destination_policy" {
  statement {
    sid     = "AllowSourceAccountsToSubscribe"
    effect  = "Allow"
    actions = ["logs:PutSubscriptionFilter"]

    principals {
      type        = "AWS"
      identifiers = var.source_account_ids
    }

    resources = [aws_cloudwatch_log_destination.destination.arn]
  }

  dynamic "statement" {
    for_each = length(var.destination_policy_source_organization_id) > 0 ? [1] : []

    content {
      sid     = "AllowOrganizationToSubscribe"
      effect  = "Allow"
      actions = ["logs:PutSubscriptionFilter"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = [var.destination_policy_source_organization_id]
      }

      resources = [aws_cloudwatch_log_destination.destination.arn]
    }
  }
}

resource "aws_cloudwatch_log_destination_policy" "destination" {
  provider         = aws.destination
  destination_name = aws_cloudwatch_log_destination.destination.name
  access_policy    = data.aws_iam_policy_document.destination_policy.json
}
