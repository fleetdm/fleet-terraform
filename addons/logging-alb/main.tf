data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {

  kms_policies = concat([{
    actions = ["kms:*"],
    principals = [{
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }]
    resources = ["*"]

    },
    {
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]
      principals = [{
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
      }]
  }], var.extra_kms_policies)

  s3_path_prefix = coalesce(var.alt_path_prefix, var.prefix)
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

resource "aws_kms_key" "logs" {
  policy              = data.aws_iam_policy_document.kms.json
  enable_key_rotation = true
}

resource "aws_kms_alias" "logs_alias" {
  name_prefix   = "alias/${var.prefix}-logs"
  target_key_id = aws_kms_key.logs.id
}

module "s3_bucket_for_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.0.0"

  bucket = "${var.prefix}-alb-logs"

  # Allow deletion of non-empty bucket
  force_destroy = true

  attach_elb_log_delivery_policy        = true # Required for ALB logs
  attach_lb_log_delivery_policy         = true # Required for ALB/NLB logs
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
    location      = "s3://${module.s3_bucket_for_logs.s3_bucket_id}/${local.s3_path_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${data.aws_region.current.region}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "regex-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
      parameters = {
        "serialization.format" = "1"
        "input.regex"          = "([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \\\"([^ ]*) (.*) (- |[^ ]*)\\\" \\\"([^\\\"]*)\\\" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) \\\"([^\\\"]*)\\\" \\\"([^\\\"]*)\\\" \\\"([^\\\"]*)\\\" ([-.0-9]*) ([^ ]*) \\\"([^\\\"]*)\\\" \\\"([^\\\"]*)\\\" \\\"([^ ]*)\\\" \\\"([^\\\\s]+?)\\\" \\\"([^\\\\s]+)\\\" \\\"([^ ]*)\\\" \\\"([^ ]*)\\\" ?([^ ]*)?( .*)?"
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
    "storage.location.template"    = "s3://${module.s3_bucket_for_logs.s3_bucket_id}/${local.s3_path_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/${data.aws_region.current.region}/${"$"}{day}"
  }
}
