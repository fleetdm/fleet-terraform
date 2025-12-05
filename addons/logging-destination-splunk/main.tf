data "aws_region" "current" {}

resource "aws_s3_bucket" "splunk-failure" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2022-07-01  #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15
  bucket_prefix = var.s3_bucket_config.name_prefix
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "splunk-failure" {
  bucket = aws_s3_bucket.splunk-failure.bucket
  rule {
    status = "Enabled"
    id     = "expire"
    filter {
      prefix = ""
    }
    expiration {
      days = var.s3_bucket_config.expires_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "splunk-failure" {
  bucket = aws_s3_bucket.splunk-failure.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "splunk-failure" {
  bucket                  = aws_s3_bucket.splunk-failure.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "firehose_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    // This bucket is single-purpose and using a wildcard is not problematic
    resources = [
      aws_s3_bucket.splunk-failure.arn,
      "${aws_s3_bucket.splunk-failure.arn}/*"
    ] #tfsec:ignore:aws-iam-no-policy-wildcards
  }
}

resource "aws_iam_policy" "firehose" {
  name   = var.iam_policy_name
  policy = data.aws_iam_policy_document.firehose_policy.json
}

resource "aws_iam_role" "firehose" {
  assume_role_policy = data.aws_iam_policy_document.osquery_firehose_assume_role.json
}

resource "aws_iam_role_policy_attachment" "firehose" {
  policy_arn = aws_iam_policy.firehose.arn
  role       = aws_iam_role.firehose.name
}

data "aws_iam_policy_document" "osquery_firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["firehose.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "splunk" {
  for_each    = var.log_destinations
  name        = each.value.name
  destination = "splunk"

  server_side_encryption {
    enabled = true
  }

  splunk_configuration {
    hec_endpoint               = each.value.hec_endpoint
    hec_token                  = each.value.hec_token
    hec_acknowledgment_timeout = each.value.hec_acknowledgement_timeout
    hec_endpoint_type          = each.value.hec_endpoint_type
    s3_backup_mode             = "FailedEventsOnly"

    s3_configuration {
      error_output_prefix = each.value.s3_error_output_prefix
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = aws_s3_bucket.splunk-failure.arn
      buffering_size      = each.value.s3_buffering_size
      buffering_interval  = each.value.s3_buffering_interval
      compression_format  = var.compression_format
    }
  }
}

data "aws_iam_policy_document" "firehose-logging" {
  statement {
    actions = [
      "firehose:DescribeDeliveryStream",
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [for stream in keys(var.log_destinations) : aws_kinesis_firehose_delivery_stream.splunk[stream].arn]
  }
}

resource "aws_iam_policy" "firehose-logging" {
  description = "An IAM policy for fleet to log to Splunk via Firehose"
  policy      = data.aws_iam_policy_document.firehose-logging.json
}
