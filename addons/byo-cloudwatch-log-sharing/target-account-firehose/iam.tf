locals {
  cloudwatch_destination_role_name = coalesce(
    var.cloudwatch_destination.role_name,
    "fleet-log-sharing-firehose-destination-role"
  )
  firehose_role_name = coalesce(
    var.firehose.role_name,
    "fleet-log-sharing-firehose-delivery-role"
  )

  cloudwatch_destination_policy_name = coalesce(
    var.cloudwatch_destination.policy_name,
    "${local.cloudwatch_destination_role_name}-policy"
  )
  firehose_policy_name = coalesce(
    var.firehose.policy_name,
    "${local.firehose_role_name}-policy"
  )
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.destination.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = local.allowed_source_arns
    }
  }
}

resource "aws_iam_role" "destination" {
  provider           = aws.destination
  name               = local.cloudwatch_destination_role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "destination" {
  statement {
    effect = "Allow"
    actions = [
      "firehose:DescribeDeliveryStream",
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.destination.arn]
  }
}

resource "aws_iam_policy" "destination" {
  provider = aws.destination
  name     = local.cloudwatch_destination_policy_name
  policy   = data.aws_iam_policy_document.destination.json
  tags     = var.tags
}

resource "aws_iam_role_policy_attachment" "destination" {
  provider   = aws.destination
  role       = aws_iam_role.destination.name
  policy_arn = aws_iam_policy.destination.arn
}
