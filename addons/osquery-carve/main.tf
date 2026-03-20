// No versioning on this bucket is by design.
// Bucket logging is not supported in our Fleet Terraforms at the moment. It can be enabled by the
// organizations deploying Fleet, and we will evaluate the possibility of providing this capability
// in the future.

locals {
  osquery_carve_provided_kms_key_ref = var.osquery_carve_s3_bucket.kms.kms_key_arn
  osquery_carve_create_kms_key       = local.osquery_carve_provided_kms_key_ref == null && var.osquery_carve_s3_bucket.kms.create_kms_key == true
  osquery_carve_kms_key_id = local.osquery_carve_provided_kms_key_ref != null ? data.aws_kms_key.osquery_carve_provided[0].key_id : (
    local.osquery_carve_create_kms_key == true ? aws_kms_key.osquery_carve[0].id : null
  )
  osquery_carve_kms_key_arn = local.osquery_carve_provided_kms_key_ref != null ? data.aws_kms_key.osquery_carve_provided[0].arn : (
    local.osquery_carve_create_kms_key == true ? aws_kms_key.osquery_carve[0].arn : null
  )

  kms_base_policy_statements = var.osquery_carve_s3_bucket.kms.kms_base_policy != null ? var.osquery_carve_s3_bucket.kms.kms_base_policy : [
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

  osquery_carve_kms_task_role_statements = var.osquery_carve_s3_bucket.kms.fleet_role_arn != null ? [
    {
      sid    = "AllowFleetRoleUseOfTheKey"
      effect = "Allow"
      actions = [
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Encrypt*",
        "kms:Describe*",
        "kms:Decrypt*"
      ]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = [var.osquery_carve_s3_bucket.kms.fleet_role_arn]
      }
      conditions = []
    }
  ] : []

  osquery_carve_kms_policy = local.osquery_carve_kms_key_arn != null ? [{
    sid = "AllowOsqueryCarveKMSAccess"
    actions = [
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Encrypt*",
      "kms:Describe*",
      "kms:Decrypt*"
    ]
    resources = [local.osquery_carve_kms_key_arn]
    effect    = "Allow"
  }] : []
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_kms_key" "osquery_carve_provided" {
  count  = local.osquery_carve_provided_kms_key_ref != null ? 1 : 0
  key_id = local.osquery_carve_provided_kms_key_ref
}

resource "aws_s3_bucket" "main" { #tfsec:ignore:aws-s3-encryption-customer-key:exp:2028-07-01  #tfsec:ignore:aws-s3-enable-versioning #tfsec:ignore:aws-s3-enable-bucket-logging:exp:2028-07-01
  bucket = var.osquery_carve_s3_bucket.name
}

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.bucket
  rule {
    status = "Enabled"
    id     = "expire"
    expiration {
      days = var.osquery_carve_s3_bucket.expires_days
    }
    filter {}
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.bucket
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.osquery_carve_kms_key_id
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_kms_key" "osquery_carve" {
  count               = local.osquery_carve_create_kms_key ? 1 : 0
  description         = "CMK for Fleet osquery carve S3 bucket object encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.osquery_carve_kms[0].json
}

resource "aws_kms_alias" "osquery_carve" {
  count         = local.osquery_carve_create_kms_key ? 1 : 0
  target_key_id = aws_kms_key.osquery_carve[0].id
  name          = "alias/${var.osquery_carve_s3_bucket.kms.kms_alias}"
}

data "aws_iam_policy_document" "osquery_carve_kms" {
  count = local.osquery_carve_create_kms_key ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.osquery_carve_s3_bucket.kms.extra_kms_policies,
      local.osquery_carve_kms_task_role_statements
    )
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

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "main" {
  statement {
    actions = [
      "s3:GetObject*",
      "s3:PutObject*",
      "s3:ListBucket*",
      "s3:ListMultipartUploadParts*",
      "s3:DeleteObject",
      "s3:CreateMultipartUpload",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
  }

  dynamic "statement" {
    for_each = local.osquery_carve_kms_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }
}

resource "aws_iam_policy" "main" {
  policy = data.aws_iam_policy_document.main.json
}
