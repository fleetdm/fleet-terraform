data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  provider           = aws.target
  name               = var.firehose_role_name
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
      "s3:PutObjectAcl",
    ]
    resources = [
      aws_s3_bucket.destination.arn,
      "${aws_s3_bucket.destination.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "firehose" {
  provider = aws.target
  name     = "${var.firehose_role_name}-policy"
  policy   = data.aws_iam_policy_document.firehose.json
  tags     = var.tags
}

resource "aws_iam_role_policy_attachment" "firehose" {
  provider   = aws.target
  role       = aws_iam_role.firehose.name
  policy_arn = aws_iam_policy.firehose.arn
}

resource "aws_kinesis_firehose_delivery_stream" "destination" {
  provider    = aws.target
  name        = var.firehose_delivery_stream_name
  destination = "extended_s3"

  extended_s3_configuration {
    bucket_arn          = aws_s3_bucket.destination.arn
    role_arn            = aws_iam_role.firehose.arn
    prefix              = var.s3_prefix
    error_output_prefix = var.s3_error_output_prefix
    buffering_size      = var.buffering_size
    buffering_interval  = var.buffering_interval
    compression_format  = var.compression_format
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.destination.account_id == data.aws_caller_identity.target.account_id
      error_message = "aws.destination and aws.target providers must use the same AWS account."
    }
  }
}
