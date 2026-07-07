data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Resolve per-destination bucket names: use explicit bucket_name if set,
  # otherwise fall back to the default pattern.
  resolved_bucket_names = {
    for key, cfg in var.log_destinations : key => (
      cfg.bucket_name != null ? cfg.bucket_name : "${var.s3_bucket_name}-${key}"
    )
  }

  # Resolve per-destination lifecycle expiration: use explicit value if set,
  # otherwise fall back to the global default.
  resolved_lifecycle_days = {
    for key, cfg in var.log_destinations : key => (
      cfg.lifecycle_expires_days != null ? cfg.lifecycle_expires_days : var.s3_lifecycle_expires_days
    )
  }

  # Set of bucket keys that have lifecycle expiration enabled.
  lifecycle_bucket_keys = toset([
    for key, days in local.resolved_lifecycle_days : local.bucket_key_for[key] if days > 0
  ])

  # Per-bucket-key lifecycle days (max of all destinations sharing that bucket).
  lifecycle_days_by_bucket = {
    for bk in local.lifecycle_bucket_keys : bk => max([
      for key, days in local.resolved_lifecycle_days : days if local.bucket_key_for[key] == bk
    ]...)
  }
  # In legacy mode (default), each log type gets its own bucket.
  # In consolidated mode, all share one bucket.
  bucket_count = var.consolidate_to_single_bucket ? 1 : length(var.log_destinations)

  # Bucket names: use resolved names (explicit or default pattern)
  bucket_names = var.consolidate_to_single_bucket ? {
    _all = var.s3_bucket_name
  } : local.resolved_bucket_names

  # Map each log destination key to its bucket key
  # In consolidated mode, all map to "_all"
  bucket_key_for = {
    for key in keys(var.log_destinations) : key => (var.consolidate_to_single_bucket ? "_all" : key)
  }

  # Unique set of bucket keys to iterate over
  bucket_keys = toset(values(local.bucket_key_for))

  # Bucket name lookup by bucket key
  bucket_name_by_key = {
    for bk in local.bucket_keys : bk => local.bucket_names[bk]
  }

  # KMS key ARN to use
  kms_key_arn = var.server_side_encryption_enabled ? (
    length(var.kms_key_arn) > 0 ? var.kms_key_arn : aws_kms_key.firehose_key[0].arn
  ) : ""
}

# ── S3 Buckets ────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "destination" {
  for_each = local.bucket_keys #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15

  bucket        = local.bucket_name_by_key[each.key]
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_public_access_block" "destination" {
  for_each = local.bucket_keys

  bucket                  = aws_s3_bucket.destination[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  for_each = var.server_side_encryption_enabled ? local.bucket_keys : toset([])

  bucket = aws_s3_bucket.destination[each.key].id
  rule {
    blocked_encryption_types = ["NONE"]
    bucket_key_enabled       = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "destination" {
  for_each = local.lifecycle_bucket_keys

  bucket = aws_s3_bucket.destination[each.key].bucket
  rule {
    filter {}
    status = "Enabled"
    id     = "expire"
    expiration {
      days = local.lifecycle_days_by_bucket[each.key]
    }
  }
}

# ── Deny Insecure Transport Bucket Policies ──────────────────────────────────

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = local.bucket_keys

  statement {
    sid     = "DenyNonHTTPS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.destination[each.key].arn,
      "${aws_s3_bucket.destination[each.key].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "deny_insecure_transport" {
  for_each = local.bucket_keys

  bucket = aws_s3_bucket.destination[each.key].id
  policy = data.aws_iam_policy_document.deny_insecure_transport[each.key].json
}

# ── KMS Key ──────────────────────────────────────────────────────────────────

resource "aws_kms_key" "firehose_key" {
  count       = var.server_side_encryption_enabled && length(var.kms_key_arn) == 0 ? 1 : 0
  description = "KMS key for encrypting Firehose data."
}

# ── Firehose IAM Roles & Policies ────────────────────────────────────────────

# One role per bucket (shared by all streams writing to that bucket)
resource "aws_iam_role" "firehose" {
  for_each = local.bucket_keys

  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role[each.key].json
}

data "aws_iam_policy_document" "firehose_assume_role" {
  for_each = local.bucket_keys

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["firehose.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "firehose_policy" {
  for_each = local.bucket_keys

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
      aws_s3_bucket.destination[each.key].arn,
      "${aws_s3_bucket.destination[each.key].arn}/*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["logs:PutLogEvents"]
    resources = [
      for dest_key, bk in local.bucket_key_for : bk == each.key ? "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/kinesisfirehose/${var.log_destinations[dest_key].name}:*" : null
      if bk == each.key
    ]
  }

  dynamic "statement" {
    for_each = var.server_side_encryption_enabled ? [1] : []

    content {
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [local.kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "firehose" {
  for_each = local.bucket_keys

  name   = var.prefix == "" ? "firehose_logging_${each.key}" : "${var.prefix}_firehose_logging_${each.key}"
  policy = data.aws_iam_policy_document.firehose_policy[each.key].json
}

resource "aws_iam_role_policy_attachment" "firehose" {
  for_each = local.bucket_keys

  policy_arn = aws_iam_policy.firehose[each.key].arn
  role       = aws_iam_role.firehose[each.key].name
}

# ── Firehose Delivery Streams ────────────────────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "fleet_log_destinations" {
  for_each    = var.log_destinations
  name        = each.value.name
  destination = "extended_s3"

  dynamic "server_side_encryption" {
    for_each = var.server_side_encryption_enabled ? [1] : []
    content {
      enabled  = var.server_side_encryption_enabled
      key_arn  = local.kms_key_arn
      key_type = "CUSTOMER_MANAGED_CMK"
    }
  }

  extended_s3_configuration {
    bucket_arn          = aws_s3_bucket.destination[local.bucket_key_for[each.key]].arn
    role_arn            = aws_iam_role.firehose[local.bucket_key_for[each.key]].arn
    prefix              = each.value.prefix
    error_output_prefix = each.value.error_output_prefix
    buffering_size      = each.value.buffering_size
    buffering_interval  = each.value.buffering_interval
    compression_format  = each.value.compression_format
  }
}

# ── Fleet IAM Policy ─────────────────────────────────────────────────────────

resource "aws_iam_policy" "firehose-logging" {
  description = "An IAM policy for fleet to log to Firehose destinations"
  policy      = data.aws_iam_policy_document.firehose_logging.json
}

data "aws_iam_policy_document" "firehose_logging" {
  statement {
    actions = [
      "firehose:DescribeDeliveryStream",
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [
      for stream in aws_kinesis_firehose_delivery_stream.fleet_log_destinations : stream.arn
    ]
  }

  dynamic "statement" {
    for_each = var.server_side_encryption_enabled ? [1] : []

    content {
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [local.kms_key_arn]
    }
  }
}
