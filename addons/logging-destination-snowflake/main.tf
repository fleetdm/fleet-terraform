data "aws_region" "current" {}

resource "aws_s3_bucket" "snowflake-failure" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2022-07-01  #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15
  bucket_prefix = var.s3_bucket_config.name_prefix
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "snowflake-failure" {
  bucket = aws_s3_bucket.snowflake-failure.bucket
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

resource "aws_s3_bucket_server_side_encryption_configuration" "snowflake-failure" {
  bucket = aws_s3_bucket.snowflake-failure.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "snowflake-failure" {
  bucket                  = aws_s3_bucket.snowflake-failure.id
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
      aws_s3_bucket.snowflake-failure.arn,
      "${aws_s3_bucket.snowflake-failure.arn}/*"
    ] #tfsec:ignore:aws-iam-no-policy-wildcards
  }
}

resource "aws_iam_policy" "firehose" {
  name   = "snowflake_firehose_policy"
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

resource "aws_kinesis_firehose_delivery_stream" "snowflake" {
  for_each    = var.log_destinations
  name        = each.value.name
  destination = "snowflake"

  server_side_encryption {
    enabled = true
  }

  snowflake_configuration {
    account_url          = var.snowflake_shared.account_url
    database             = each.value.database
    private_key          = var.snowflake_shared.private_key
    key_passphrase       = var.snowflake_shared.key_passphrase
    schema               = each.value.schema
    table                = each.value.table
    user                 = var.snowflake_shared.user
    buffering_size       = each.value.buffering_size
    buffering_interval   = each.value.buffering_interval
    role_arn             = aws_iam_role.firehose.arn
    s3_backup_mode       = "FailedDataOnly"
    data_loading_option  = each.value.data_loading_option
    content_column_name  = each.value.content_column_name
    metadata_column_name = each.value.metadata_column_name

    snowflake_role_configuration {
      enabled        = var.snowflake_shared.snowflake_role_configuration.enabled
      snowflake_role = var.snowflake_shared.snowflake_role_configuration.snowflake_role
    }

    dynamic "snowflake_vpc_configuration" {
      for_each = var.snowflake_shared.snowflake_vpc_configuration.private_link_vpce_id == null ? [] : [1]

      content {
        private_link_vpce_id = var.snowflake_shared.snowflake_vpc_configuration.private_link_vpce_id
      }
    }

    s3_configuration {
      error_output_prefix = each.value.s3_error_output_prefix
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = aws_s3_bucket.snowflake-failure.arn
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
    resources = [for stream in keys(var.log_destinations) : aws_kinesis_firehose_delivery_stream.snowflake[stream].arn]
  }
}

resource "aws_iam_policy" "firehose-logging" {
  description = "An IAM policy for fleet to log to Snowflake via Firehose"
  policy      = data.aws_iam_policy_document.firehose-logging.json
}
