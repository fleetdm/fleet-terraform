data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  landing_bucket_name = "${var.prefix}-alb-logs"
  archive_bucket_name = "${var.prefix}-alb-logs-archive"

  kms_policies = concat([
    {
      actions = ["kms:*"]
      principals = [{
        type        = "AWS"
        identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
      }]
      resources = ["*"]
    },
    {
      actions = [
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]
      principals = [{
        type        = "AWS"
        identifiers = [aws_iam_role.s3_replication.arn]
      }]
    },
  ], var.extra_kms_policies)

  s3_path_prefix = coalesce(var.alt_path_prefix, var.prefix)
}

check "landing_bucket_retention_recommendation" {
  assert {
    condition     = var.landing_s3_expiration_days == 1
    error_message = "landing_s3_expiration_days should normally be 1. Increase it only temporarily during a migration or backfill window."
  }
}


data "aws_iam_policy_document" "kms" {
  dynamic "statement" {
    for_each = local.kms_policies
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
      dynamic "principals" {
        for_each = try(statement.value.principals, [])
        content {
          type        = principals.value.type
          identifiers = principals.value.identifiers
        }
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

data "aws_iam_policy_document" "s3_log_bucket" {
  count = var.extra_s3_log_policies == [] ? 0 : 1
  dynamic "statement" {
    for_each = var.extra_s3_log_policies
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
      dynamic "principals" {
        for_each = try(statement.value.principals, [])
        content {
          type        = principals.value.type
          identifiers = principals.value.identifiers
        }
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

data "aws_iam_policy_document" "s3_athena_bucket" {
  count = var.extra_s3_athena_policies == [] ? 0 : 1
  dynamic "statement" {
    for_each = var.extra_s3_athena_policies
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
      dynamic "principals" {
        for_each = try(statement.value.principals, [])
        content {
          type        = principals.value.type
          identifiers = principals.value.identifiers
        }
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

data "aws_iam_policy_document" "s3_replication_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "s3_replication" {
  statement {
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [
      module.s3_bucket_for_logs.s3_bucket_arn,
    ]
  }

  statement {
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = [
      "${module.s3_bucket_for_logs.s3_bucket_arn}/*",
    ]
  }

  statement {
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
      "s3:ObjectOwnerOverrideToBucketOwner",
    ]
    resources = [
      "${aws_s3_bucket.logs_archive.arn}/*",
    ]
  }

  statement {
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [
      aws_kms_key.logs.arn,
    ]
  }
}

resource "aws_kms_key" "logs" {
  policy              = data.aws_iam_policy_document.kms.json
  enable_key_rotation = true
}

resource "aws_kms_alias" "logs_alias" {
  name_prefix   = "alias/${var.prefix}-logs"
  target_key_id = aws_kms_key.logs.id
}

resource "aws_iam_role" "s3_replication" {
  name_prefix        = "${var.prefix}-alb-log-replication-"
  assume_role_policy = data.aws_iam_policy_document.s3_replication_assume_role.json
}

resource "aws_iam_role_policy" "s3_replication" {
  name_prefix = "${var.prefix}-alb-log-replication-"
  role        = aws_iam_role.s3_replication.id
  policy      = data.aws_iam_policy_document.s3_replication.json
}

module "s3_bucket_for_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.0.0"

  bucket = local.landing_bucket_name

  # Allow deletion of non-empty bucket
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
  attach_policy                         = var.extra_s3_log_policies != []
  policy                                = var.extra_s3_log_policies != [] ? data.aws_iam_policy_document.s3_log_bucket[0].json : null
  block_public_acls                     = true
  block_public_policy                   = true
  ignore_public_acls                    = true
  restrict_public_buckets               = true
  acl                                   = "private"
  control_object_ownership              = true
  object_ownership                      = "ObjectWriter"
  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      bucket_key_enabled = true
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }
  lifecycle_rule = [
    {
      id      = "landing-expiration"
      enabled = true

      expiration = {
        days = var.landing_s3_expiration_days
      }
      filter = []
    }
  ]
}

resource "aws_s3_bucket" "logs_archive" {
  bucket        = local.archive_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.logs.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  rule {
    id     = "archive-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = var.s3_transition_days
      storage_class = "ONEZONE_IA"
    }

    expiration {
      days = var.s3_expiration_days
    }

    noncurrent_version_expiration {
      newer_noncurrent_versions = var.s3_newer_noncurrent_versions
      noncurrent_days           = var.s3_noncurrent_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "logs" {
  depends_on = [
    module.s3_bucket_for_logs,
    aws_s3_bucket_versioning.logs_archive,
    aws_iam_role_policy.s3_replication,
  ]

  bucket = module.s3_bucket_for_logs.s3_bucket_id
  role   = aws_iam_role.s3_replication.arn

  rule {
    id     = "landing-to-archive"
    status = "Enabled"

    delete_marker_replication {
      status = "Disabled"
    }

    filter {}

    destination {
      bucket = aws_s3_bucket.logs_archive.arn

      encryption_configuration {
        replica_kms_key_id = aws_kms_key.logs.arn
      }
    }
  }
}

resource "aws_athena_database" "logs" {
  count  = var.enable_athena == true ? 1 : 0
  name   = replace("${var.prefix}-alb-logs", "-", "_")
  bucket = module.athena-s3-bucket[0].s3_bucket_id
}

module "athena-s3-bucket" {
  count   = var.enable_athena == true ? 1 : 0
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.0.0"

  bucket = "${var.prefix}-alb-logs-athena"

  # Allow deletion of non-empty bucket
  force_destroy = true

  attach_elb_log_delivery_policy        = true # Required for ALB logs
  attach_lb_log_delivery_policy         = true # Required for ALB/NLB logs
  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
  attach_policy                         = var.extra_s3_athena_policies != []
  policy                                = var.extra_s3_athena_policies != [] ? data.aws_iam_policy_document.s3_athena_bucket[0].json : null
  block_public_acls                     = true
  block_public_policy                   = true
  ignore_public_acls                    = true
  restrict_public_buckets               = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = aws_kms_key.logs.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
  lifecycle_rule = [
    {
      id      = "log"
      enabled = true

      transition = [
        {
          days          = var.s3_transition_days
          storage_class = "ONEZONE_IA"
        }
      ]
      expiration = {
        days = var.s3_expiration_days
      }
      noncurrent_version_expiration = {
        newer_noncurrent_versions = var.s3_newer_noncurrent_versions
        days                      = var.s3_noncurrent_version_expiration_days
      }
      filter = []
    }
  ]
}

resource "aws_athena_workgroup" "logs" {
  count = var.enable_athena == true ? 1 : 0
  name  = "${var.prefix}-logs"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${module.athena-s3-bucket[0].s3_bucket_id}/output/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.logs.arn
      }
    }
  }

  force_destroy = true
}

resource "aws_glue_catalog_table" "partitioned_alb_logs" {
  count         = var.enable_athena == true ? 1 : 0
  name          = "partitioned_alb_logs"
  database_name = aws_athena_database.logs[0].name
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.logs_archive.id}/${local.s3_path_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${data.aws_region.current.region}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "regex-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
      parameters = {
        "serialization.format" = "1"
        "input.regex"          = "([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \"([^ ]*) (.*) (- |[^ ]*)\" \"([^\"]*)\" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ([-.0-9]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^ ]*)\" \"([^\\s]+?)\" \"([^\\s]+)\" \"([^ ]*)\" \"([^ ]*)\" ?([^ ]*)? ?( .*)?"
      }
    }

    columns {
      name = "type"
      type = "string"
    }
    columns {
      name = "time"
      type = "string"
    }
    columns {
      name = "elb"
      type = "string"
    }
    columns {
      name = "client_ip"
      type = "string"
    }
    columns {
      name = "client_port"
      type = "int"
    }
    columns {
      name = "target_ip"
      type = "string"
    }
    columns {
      name = "target_port"
      type = "int"
    }
    columns {
      name = "request_processing_time"
      type = "double"
    }
    columns {
      name = "target_processing_time"
      type = "double"
    }
    columns {
      name = "response_processing_time"
      type = "double"
    }
    columns {
      name = "elb_status_code"
      type = "int"
    }
    columns {
      name = "target_status_code"
      type = "string"
    }
    columns {
      name = "received_bytes"
      type = "bigint"
    }
    columns {
      name = "sent_bytes"
      type = "bigint"
    }
    columns {
      name = "request_verb"
      type = "string"
    }
    columns {
      name = "request_url"
      type = "string"
    }
    columns {
      name = "request_proto"
      type = "string"
    }
    columns {
      name = "user_agent"
      type = "string"
    }
    columns {
      name = "ssl_cipher"
      type = "string"
    }
    columns {
      name = "ssl_protocol"
      type = "string"
    }
    columns {
      name = "target_group_arn"
      type = "string"
    }
    columns {
      name = "trace_id"
      type = "string"
    }
    columns {
      name = "domain_name"
      type = "string"
    }
    columns {
      name = "chosen_cert_arn"
      type = "string"
    }
    columns {
      name = "matched_rule_priority"
      type = "string"
    }
    columns {
      name = "request_creation_time"
      type = "string"
    }
    columns {
      name = "actions_executed"
      type = "string"
    }
    columns {
      name = "redirect_url"
      type = "string"
    }
    columns {
      name = "lambda_error_reason"
      type = "string"
    }
    columns {
      name = "target_port_list"
      type = "string"
    }
    columns {
      name = "target_status_code_list"
      type = "string"
    }
    columns {
      name = "classification"
      type = "string"
    }
    columns {
      name = "classification_reason"
      type = "string"
    }
    columns {
      name = "conn_trace_id"
      type = "string"
    }
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  parameters = {
    "EXTERNAL"                     = "TRUE"
    "projection.enabled"           = "true"
    "projection.day.type"          = "date"
    "projection.day.range"         = "2022/01/01,NOW"
    "projection.day.format"        = "yyyy/MM/dd"
    "projection.day.interval"      = "1"
    "projection.day.interval.unit" = "DAYS"
    "storage.location.template"    = "s3://${aws_s3_bucket.logs_archive.id}/${local.s3_path_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${data.aws_region.current.region}/${"$"}{day}"
  }
}
