// This module is the read side of Fleet's S3 log destinations. It creates no buckets for log data
// and never writes to them -- it points Glue tables at buckets owned by
// logging-destination-firehose (or byo-firehose-logging-destination /
// byo-kinesis-logging-destination) and layers Athena views on top so a third-party data modelling
// application can use Athena as its data connector.
//
// Because it only consumes bucket names and prefixes, it works equally well against buckets in this
// account and against cross-account BYO destinations.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  database_name        = coalesce(var.database_name, replace("${var.prefix}_fleet_logs", "-", "_"))
  workgroup_name       = coalesce(var.workgroup_name, "${var.prefix}-fleet-logs")
  results_bucket_name  = coalesce(var.query_results_bucket_name, "${var.prefix}-fleet-logs-athena")
  create_kms_key       = var.kms_key_arn == null
  kms_key_arn          = var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.athena[0].arn
  consumer_role_name   = coalesce(var.consumer_role.name, "${var.prefix}-fleet-logs-athena-consumer")
  create_consumer_role = coalesce(var.consumer_role.enabled, false)

  # Single source of truth for the raw table names, so the view SQL can reference them without
  # depending on count-indexed resource attributes.
  raw_table_names = {
    results = "${var.table_prefix}osquery_results_raw"
    status  = "${var.table_prefix}osquery_status_raw"
    audit   = "${var.table_prefix}fleet_audit_raw"
  }

  sources = {
    osquery_results = var.osquery_results
    osquery_status  = var.osquery_status
    fleet_audit     = var.fleet_audit
  }

  enabled_sources = {
    for k, v in local.sources : k => v
    if v != null && coalesce(v.enabled, true)
  }

  source_bucket_arns = distinct([
    for k, v in local.enabled_sources : "arn:${data.aws_partition.current.partition}:s3:::${v.bucket_name}"
  ])

  # The static portion of each Firehose prefix: everything before the first partition key. This is
  # the Glue table LOCATION, and the partition keys are appended to it by the projection template.
  static_prefixes = {
    for k, v in local.enabled_sources : k => try(regex("^(?P<static>.*?)dt=", v.firehose_s3_prefix).static, "")
  }

  hourly = var.partition_layout == "hourly"

  # Firehose prefix each enabled source is required to be using, so a mismatch fails at plan time
  # rather than producing a table that silently returns zero rows.
  expected_prefix_suffix = local.hourly ? "dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/" : "dt=!{timestamp:yyyy-MM-dd}/"
  expected_prefix_regex  = local.hourly ? "dt=!\\{timestamp:yyyy-MM-dd\\}/hour=!\\{timestamp:HH\\}/$" : "dt=!\\{timestamp:yyyy-MM-dd\\}/$"

  partition_columns = local.hourly ? ["dt", "hour"] : ["dt"]

  partition_keys = local.hourly ? [
    { name = "dt", type = "string", comment = "Firehose delivery date, yyyy-MM-dd. Record ARRIVAL time, not event time." },
    { name = "hour", type = "string", comment = "Firehose delivery hour, 00-23. Record ARRIVAL time, not event time." },
    ] : [
    { name = "dt", type = "string", comment = "Firehose delivery date, yyyy-MM-dd. Record ARRIVAL time, not event time." },
  ]

  projection_parameters = merge(
    {
      "EXTERNAL"                    = "TRUE"
      "classification"              = "json"
      "projection.enabled"          = "true"
      "projection.dt.type"          = "date"
      "projection.dt.range"         = "${var.projection_start_date},NOW"
      "projection.dt.format"        = "yyyy-MM-dd"
      "projection.dt.interval"      = "1"
      "projection.dt.interval.unit" = "DAYS"
    },
    local.hourly ? {
      "projection.hour.type"   = "integer"
      "projection.hour.range"  = "0,23"
      "projection.hour.digits" = "2"
    } : {}
  )

  # Partition path appended to each table's LOCATION in storage.location.template.
  location_partition_template = local.hourly ? "dt=$${dt}/hour=$${hour}/" : "dt=$${dt}/"

  # OpenX JSON SerDe. With case.insensitive = FALSE the SerDe preserves key case, which keeps
  # osquery column names and deployment-defined decoration keys intact inside the map<> columns, at
  # the cost of needing an explicit mapping for each camelCase top-level field.
  openx_serde_parameters = merge(
    {
      "case.insensitive"      = var.case_insensitive_keys ? "TRUE" : "FALSE"
      "ignore.malformed.json" = "TRUE"
      "dots.in.keys"          = "TRUE"
    },
    var.case_insensitive_keys ? {} : {
      "mapping.hostidentifier" = "hostIdentifier"
      "mapping.calendartime"   = "calendarTime"
      "mapping.unixtime"       = "unixTime"
      "mapping.diffresults"    = "diffResults"
    }
  )
}

# Fails the plan if a source's Firehose prefix does not match the configured partition_layout. The
# table location is derived from that string, so a mismatch is the difference between a working
# table and one that returns nothing.
resource "terraform_data" "validate_source_prefixes" {
  for_each = local.enabled_sources

  lifecycle {
    precondition {
      condition     = can(regex(local.expected_prefix_regex, each.value.firehose_s3_prefix))
      error_message = "${each.key}.firehose_s3_prefix (\"${each.value.firehose_s3_prefix}\") must end with \"${local.expected_prefix_suffix}\" to match partition_layout \"${var.partition_layout}\". Pass the same string to the logging module's firehose_s3_prefix and to this module."
    }

    precondition {
      condition     = !strcontains(local.static_prefixes[each.key], "!{")
      error_message = "${each.key}.firehose_s3_prefix has a Firehose expression before the first \"dt=\" partition key. The portion before \"dt=\" becomes a static Glue table location and cannot contain !{...} expressions."
    }
  }
}

resource "terraform_data" "validate_at_least_one_source" {
  lifecycle {
    precondition {
      condition     = length(local.enabled_sources) > 0
      error_message = "At least one of osquery_results, osquery_status, or fleet_audit must be set and enabled."
    }
  }
}

# ── KMS ──────────────────────────────────────────────────────────────────────

locals {
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

  # Athena writes query results and metadata with the identity that ran the query, so the consumer
  # role needs to use the key, not just read with it.
  kms_principal_statements = concat(
    local.create_consumer_role ? [
      {
        sid       = "AllowAthenaConsumerUseOfTheKey"
        effect    = "Allow"
        actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        resources = ["*"]
        principals = {
          type        = "AWS"
          identifiers = [aws_iam_role.consumer[0].arn]
        }
        conditions = []
      }
    ] : [],
  )
}

resource "aws_kms_key" "athena" {
  count               = local.create_kms_key ? 1 : 0
  description         = "CMK for ${local.workgroup_name} Athena query results and metadata."
  enable_key_rotation = true
}

resource "aws_kms_alias" "athena" {
  count         = local.create_kms_key ? 1 : 0
  target_key_id = aws_kms_key.athena[0].id
  name          = "alias/${local.workgroup_name}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type conflicts when
# concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "athena_kms" {
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
    for_each = local.kms_principal_statements
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

resource "aws_kms_key_policy" "athena" {
  count  = local.create_kms_key ? 1 : 0
  key_id = aws_kms_key.athena[0].id
  policy = data.aws_iam_policy_document.athena_kms[0].json
}

resource "terraform_data" "validate_kms_extra_policies" {
  lifecycle {
    precondition {
      condition     = length(var.kms_extra_policies) == 0 || local.create_kms_key
      error_message = "kms_extra_policies can be set only when this module is creating the CMK (kms_key_arn is null). When an existing key is supplied, its key policy remains caller-managed."
    }

    precondition {
      condition     = var.kms_base_policy == null || local.create_kms_key
      error_message = "kms_base_policy can be set only when this module is creating the CMK (kms_key_arn is null)."
    }
  }
}

# ── Query results bucket ─────────────────────────────────────────────────────

data "aws_iam_policy_document" "query_results_bucket" {
  count = length(var.extra_s3_athena_policies) == 0 ? 0 : 1

  dynamic "statement" {
    for_each = var.extra_s3_athena_policies
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      dynamic "principals" {
        for_each = try(statement.value.principals, []) == [] ? [] : [statement.value.principals]
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

module "query_results_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.12.0"

  bucket = local.results_bucket_name
  tags   = var.s3_bucket_tags

  # Query results are reproducible by re-running the query; nothing here is a system of record.
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
  attach_policy                         = length(var.extra_s3_athena_policies) > 0
  policy                                = length(var.extra_s3_athena_policies) > 0 ? data.aws_iam_policy_document.query_results_bucket[0].json : null

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      bucket_key_enabled       = true
      blocked_encryption_types = ["NONE"]
      apply_server_side_encryption_by_default = {
        kms_master_key_id = local.kms_key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-query-results"
      enabled = true
      expiration = {
        days = var.query_results_expiration_days
      }
      abort_incomplete_multipart_upload_days = 7
      filter                                 = []
    }
  ]
}

# ── Database and workgroup ───────────────────────────────────────────────────

# force_destroy defaults to false so a destroy fails loudly rather than dropping views your users
# created in this database alongside the ones this module manages.
resource "aws_athena_database" "fleet_logs" {
  name          = local.database_name
  bucket        = module.query_results_bucket.s3_bucket_id
  force_destroy = var.athena_database_force_destroy
}

resource "aws_athena_workgroup" "fleet_logs" {
  name = local.workgroup_name

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_per_query

    result_configuration {
      output_location = "s3://${module.query_results_bucket.s3_bucket_id}/output/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = local.kms_key_arn
      }
    }
  }

  force_destroy = true
}
