// Customer keys are not supported in our Fleet Terraforms at the moment. We will evaluate the
// possibility of providing this capability in the future. 
// No versioning on this bucket is by design.
// Bucket logging is not supported in our Fleet Terraforms at the moment. It can be enabled by the
// organizations deploying Fleet, and we will evaluate the possibility of providing this capability
// in the future.

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  create_kms_key = (var.firehose_sse_enabled || var.s3_kms_encryption_enabled) && length(var.kms_key_arn) == 0
  kms_key_arn    = length(var.kms_key_arn) > 0 ? var.kms_key_arn : (local.create_kms_key ? aws_kms_key.firehose[0].arn : null)
  kms_key_in_use = var.firehose_sse_enabled || var.s3_kms_encryption_enabled
  kms_alias_name = var.prefix != "" ? "${var.prefix}-firehose" : "fleet-firehose"

  kms_firehose_role_statements = local.kms_key_in_use ? [
    {
      sid    = "AllowFirehoseResultsRole"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = [aws_iam_role.firehose-results.arn]
      }
      conditions = []
    },
    {
      sid    = "AllowFirehoseStatusRole"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = [aws_iam_role.firehose-status.arn]
      }
      conditions = []
    },
    {
      sid    = "AllowFirehoseAuditRole"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = [aws_iam_role.firehose-audit.arn]
      }
      conditions = []
    },
  ] : []

  kms_base_policy_statements = var.kms_base_policy != null ? var.kms_base_policy : [
    {
      sid       = "EnableRootPermissions"
      effect    = "Allow"
      actions   = ["kms:*"]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
      }
      conditions = []
    }
  ]
}

resource "aws_s3_bucket" "osquery-results" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2022-07-01  #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15
  bucket        = var.osquery_results_s3_bucket.name
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "osquery-results" {
  bucket = aws_s3_bucket.osquery-results.bucket
  rule {
    filter {}
    status = "Enabled"
    id     = "expire"
    expiration {
      days = var.osquery_results_s3_bucket.expires_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "osquery-results" {
  bucket = aws_s3_bucket.osquery-results.bucket
  rule {
    bucket_key_enabled       = var.s3_bucket_key_enabled
    blocked_encryption_types = ["NONE"]
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.s3_kms_encryption_enabled ? local.kms_key_arn : null
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "osquery-results" {
  bucket                  = aws_s3_bucket.osquery-results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "deny_insecure_transport_osquery_results" {

  statement {
    sid     = "DenyNonHTTPS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.osquery-results.arn,
      "${aws_s3_bucket.osquery-results.arn}/*",
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

resource "aws_s3_bucket_policy" "deny_insecure_transport_osquery_results" {

  bucket = aws_s3_bucket.osquery-results.id
  policy = data.aws_iam_policy_document.deny_insecure_transport_osquery_results.json
}

// Customer keys are not supported in our Fleet Terraforms at the moment. We will evaluate the
// possibility of providing this capability in the future.
// No versioning on this bucket is by design.
// Bucket logging is not supported in our Fleet Terraforms at the moment. It can be enabled by the
// organizations deploying Fleet, and we will evaluate the possibility of providing this capability
// in the future.
resource "aws_s3_bucket" "osquery-status" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2022-07-01 #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15
  bucket        = var.osquery_status_s3_bucket.name
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "osquery-status" {
  bucket = aws_s3_bucket.osquery-status.bucket
  rule {
    filter {}
    status = "Enabled"
    id     = "expire"
    expiration {
      days = var.osquery_status_s3_bucket.expires_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "osquery-status" {
  bucket = aws_s3_bucket.osquery-status.bucket
  rule {
    bucket_key_enabled       = var.s3_bucket_key_enabled
    blocked_encryption_types = ["NONE"]
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.s3_kms_encryption_enabled ? local.kms_key_arn : null
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "osquery-status" {
  bucket                  = aws_s3_bucket.osquery-status.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "deny_insecure_transport_osquery_status" {

  statement {
    sid     = "DenyNonHTTPS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.osquery-status.arn,
      "${aws_s3_bucket.osquery-status.arn}/*",
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

resource "aws_s3_bucket_policy" "deny_insecure_transport_osquery_status" {

  bucket = aws_s3_bucket.osquery-status.id
  policy = data.aws_iam_policy_document.deny_insecure_transport_osquery_status.json
}

// Customer keys are not supported in our Fleet Terraforms at the moment. We will evaluate the
// possibility of providing this capability in the future.
// No versioning on this bucket is by design.
// Bucket logging is not supported in our Fleet Terraforms at the moment. It can be enabled by the
// organizations deploying Fleet, and we will evaluate the possibility of providing this capability
// in the future.
resource "aws_s3_bucket" "audit" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2022-07-01 #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2022-06-15
  bucket        = var.audit_s3_bucket.name
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.bucket
  rule {
    filter {}
    status = "Enabled"
    id     = "expire"
    expiration {
      days = var.audit_s3_bucket.expires_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.bucket
  rule {
    bucket_key_enabled       = var.s3_bucket_key_enabled
    blocked_encryption_types = ["NONE"]
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.s3_kms_encryption_enabled ? local.kms_key_arn : null
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "deny_insecure_transport_audit" {

  statement {
    sid     = "DenyNonHTTPS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.audit.arn,
      "${aws_s3_bucket.audit.arn}/*",
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

resource "aws_s3_bucket_policy" "deny_insecure_transport_audit" {

  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.deny_insecure_transport_audit.json
}

data "aws_iam_policy_document" "osquery_results_policy_doc" {
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
    // This bucket is single-purpose and using a wildcard is not problematic
    resources = [aws_s3_bucket.osquery-results.arn, "${aws_s3_bucket.osquery-results.arn}/*"] #tfsec:ignore:aws-iam-no-policy-wildcards
  }

  dynamic "statement" {
    for_each = local.kms_key_in_use ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [local.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["logs:PutLogEvents"]
      resources = [aws_cloudwatch_log_stream.firehose[var.osquery_results_s3_bucket.name].arn]
    }
  }
}

data "aws_iam_policy_document" "osquery_status_policy_doc" {
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
    // This bucket is single-purpose and using a wildcard is not problematic
    resources = [aws_s3_bucket.osquery-status.arn, "${aws_s3_bucket.osquery-status.arn}/*"] #tfsec:ignore:aws-iam-no-policy-wildcards
  }

  dynamic "statement" {
    for_each = local.kms_key_in_use ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [local.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["logs:PutLogEvents"]
      resources = [aws_cloudwatch_log_stream.firehose[var.osquery_status_s3_bucket.name].arn]
    }
  }
}

data "aws_iam_policy_document" "audit_policy_doc" {
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
    // This bucket is single-purpose and using a wildcard is not problematic
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"] #tfsec:ignore:aws-iam-no-policy-wildcards
  }

  dynamic "statement" {
    for_each = local.kms_key_in_use ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [local.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["logs:PutLogEvents"]
      resources = [aws_cloudwatch_log_stream.firehose[var.audit_s3_bucket.name].arn]
    }
  }
}

resource "aws_iam_policy" "firehose-results" {
  name   = var.prefix == "" ? "osquery_results_firehose_policy" : "${var.prefix}_osquery_results_firehose_policy"
  policy = data.aws_iam_policy_document.osquery_results_policy_doc.json
}

resource "aws_iam_policy" "firehose-status" {
  name   = var.prefix == "" ? "osquery_status_firehose_policy" : "${var.prefix}_osquery_status_firehose_policy"
  policy = data.aws_iam_policy_document.osquery_status_policy_doc.json
}

resource "aws_iam_policy" "firehose-audit" {
  name   = var.prefix == "" ? "audit_firehose_policy" : "${var.prefix}_audit_firehose_policy"
  policy = data.aws_iam_policy_document.audit_policy_doc.json
}

resource "aws_iam_role" "firehose-results" {
  assume_role_policy = data.aws_iam_policy_document.osquery_firehose_assume_role.json
}

resource "aws_iam_role" "firehose-status" {
  assume_role_policy = data.aws_iam_policy_document.osquery_firehose_assume_role.json
}

resource "aws_iam_role" "firehose-audit" {
  assume_role_policy = data.aws_iam_policy_document.osquery_firehose_assume_role.json
}

resource "aws_iam_role_policy_attachment" "firehose-results" {
  policy_arn = aws_iam_policy.firehose-results.arn
  role       = aws_iam_role.firehose-results.name
}

resource "aws_iam_role_policy_attachment" "firehose-status" {
  policy_arn = aws_iam_policy.firehose-status.arn
  role       = aws_iam_role.firehose-status.name
}

resource "aws_iam_role_policy_attachment" "firehose-audit" {
  policy_arn = aws_iam_policy.firehose-audit.arn
  role       = aws_iam_role.firehose-audit.name
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

resource "aws_kinesis_firehose_delivery_stream" "osquery_results" {
  name        = var.osquery_results_s3_bucket.name
  destination = "extended_s3"

  dynamic "server_side_encryption" {
    for_each = var.firehose_sse_enabled ? [1] : []
    content {
      enabled  = true
      key_arn  = local.kms_key_arn
      key_type = "CUSTOMER_MANAGED_CMK"
    }
  }

  extended_s3_configuration {
    buffering_size      = var.firehose_buffering_size
    buffering_interval  = var.firehose_buffering_interval
    prefix              = var.firehose_s3_prefix
    error_output_prefix = var.firehose_s3_error_output_prefix
    compression_format  = var.compression_format
    role_arn            = aws_iam_role.firehose-results.arn
    bucket_arn          = aws_s3_bucket.osquery-results.arn

    dynamic "cloudwatch_logging_options" {
      for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
      content {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose[var.osquery_results_s3_bucket.name].name
        log_stream_name = aws_cloudwatch_log_stream.firehose[var.osquery_results_s3_bucket.name].name
      }
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "osquery_status" {
  name        = var.osquery_status_s3_bucket.name
  destination = "extended_s3"

  dynamic "server_side_encryption" {
    for_each = var.firehose_sse_enabled ? [1] : []
    content {
      enabled  = true
      key_arn  = local.kms_key_arn
      key_type = "CUSTOMER_MANAGED_CMK"
    }
  }

  extended_s3_configuration {
    buffering_size      = var.firehose_buffering_size
    buffering_interval  = var.firehose_buffering_interval
    prefix              = var.firehose_s3_prefix
    error_output_prefix = var.firehose_s3_error_output_prefix
    compression_format  = var.compression_format
    role_arn            = aws_iam_role.firehose-status.arn
    bucket_arn          = aws_s3_bucket.osquery-status.arn

    dynamic "cloudwatch_logging_options" {
      for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
      content {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose[var.osquery_status_s3_bucket.name].name
        log_stream_name = aws_cloudwatch_log_stream.firehose[var.osquery_status_s3_bucket.name].name
      }
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = var.audit_s3_bucket.name
  destination = "extended_s3"

  dynamic "server_side_encryption" {
    for_each = var.firehose_sse_enabled ? [1] : []
    content {
      enabled  = true
      key_arn  = local.kms_key_arn
      key_type = "CUSTOMER_MANAGED_CMK"
    }
  }

  extended_s3_configuration {
    buffering_size      = var.firehose_buffering_size
    buffering_interval  = var.firehose_buffering_interval
    prefix              = var.firehose_s3_prefix
    error_output_prefix = var.firehose_s3_error_output_prefix
    compression_format  = var.compression_format
    role_arn            = aws_iam_role.firehose-audit.arn
    bucket_arn          = aws_s3_bucket.audit.arn

    dynamic "cloudwatch_logging_options" {
      for_each = var.firehose_cloudwatch_logging_enabled ? [1] : []
      content {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose[var.audit_s3_bucket.name].name
        log_stream_name = aws_cloudwatch_log_stream.firehose[var.audit_s3_bucket.name].name
      }
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
    resources = [
      aws_kinesis_firehose_delivery_stream.osquery_results.arn,
      aws_kinesis_firehose_delivery_stream.osquery_status.arn,
      aws_kinesis_firehose_delivery_stream.audit.arn,
    ]
  }
}

resource "aws_iam_policy" "firehose-logging" {
  description = "An IAM policy for fleet to log to Firehose destinations"
  policy      = data.aws_iam_policy_document.firehose-logging.json
}

resource "aws_kms_key" "firehose" {
  count               = local.create_kms_key ? 1 : 0
  description         = "CMK for encrypting Firehose delivery stream and S3 data."
  enable_key_rotation = true
}

resource "aws_kms_alias" "firehose" {
  count         = local.create_kms_key ? 1 : 0
  target_key_id = aws_kms_key.firehose[0].id
  name          = "alias/${local.kms_alias_name}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "firehose_kms" {
  count = local.create_kms_key ? 1 : 0

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }

  dynamic "statement" {
    for_each = var.kms_extra_policies
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }

  dynamic "statement" {
    for_each = local.kms_firehose_role_statements
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key_policy" "firehose" {
  count  = local.create_kms_key ? 1 : 0
  key_id = aws_kms_key.firehose[0].id
  policy = data.aws_iam_policy_document.firehose_kms[0].json
}

check "kms_base_policy_requires_module_managed_cmk" {
  assert {
    condition     = var.kms_base_policy == null || local.create_kms_key == true
    error_message = "kms_base_policy is not used by logging-destination-firehose unless this module is creating the CMK. When kms_key_arn is provided, external key policies remain caller-managed."
  }
}

check "kms_extra_policies_require_module_managed_cmk" {
  assert {
    condition     = length(var.kms_extra_policies) == 0 || local.create_kms_key == true
    error_message = "kms_extra_policies can be set only when logging-destination-firehose is creating the CMK."
  }
}

resource "aws_cloudwatch_log_group" "firehose" {
  for_each = var.firehose_cloudwatch_logging_enabled ? toset([
    var.osquery_results_s3_bucket.name,
    var.osquery_status_s3_bucket.name,
    var.audit_s3_bucket.name,
  ]) : []

  name              = "/aws/kinesisfirehose/${each.value}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose" {
  for_each = var.firehose_cloudwatch_logging_enabled ? toset([
    var.osquery_results_s3_bucket.name,
    var.osquery_status_s3_bucket.name,
    var.audit_s3_bucket.name,
  ]) : []

  name           = each.value
  log_group_name = aws_cloudwatch_log_group.firehose[each.value].name
}
