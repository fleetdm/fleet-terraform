variable "prefix" {
  description = "Prefix used to name the Athena database, workgroup, query-results bucket, and IAM resources."
  type        = string
  default     = "fleet"
}

variable "database_name" {
  description = "Glue/Athena database name. Defaults to `<prefix>_fleet_logs` with dashes replaced by underscores."
  type        = string
  default     = null
}

variable "workgroup_name" {
  description = "Athena workgroup name. Defaults to `<prefix>-fleet-logs`."
  type        = string
  default     = null
}

# ── Log sources ──────────────────────────────────────────────────────────────
#
# Each source takes the bucket the delivery stream writes to and the *exact*
# `firehose_s3_prefix` string configured on that stream. Passing the identical
# string to both modules keeps the table LOCATION and the delivered keys in
# sync from a single source of truth in the caller.

variable "osquery_results" {
  description = <<-EOT
    osquery result log source. `bucket_name` is the S3 bucket the results delivery stream writes to.
    `firehose_s3_prefix` must be the same value passed to the delivery stream's `firehose_s3_prefix`,
    including the `!{timestamp:...}` expressions, so the Glue table location can be derived from it.
  EOT
  type = object({
    enabled            = optional(bool, true)
    bucket_name        = string
    firehose_s3_prefix = string
  })
  default = null
}

variable "osquery_status" {
  description = "osquery status log source. See `osquery_results` for the shape and prefix requirements."
  type = object({
    enabled            = optional(bool, true)
    bucket_name        = string
    firehose_s3_prefix = string
  })
  default = null
}

variable "fleet_audit" {
  description = "Fleet activity audit log source. See `osquery_results` for the shape and prefix requirements."
  type = object({
    enabled            = optional(bool, true)
    bucket_name        = string
    firehose_s3_prefix = string
  })
  default = null
}

# ── Partitioning ─────────────────────────────────────────────────────────────

variable "partition_layout" {
  description = <<-EOT
    Partition granularity delivered by Firehose. `hourly` expects
    `<static>/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/`, `daily` expects
    `<static>/dt=!{timestamp:yyyy-MM-dd}/`. Partition projection is used in both cases, so no
    crawler or MSCK REPAIR is required.
  EOT
  type        = string
  default     = "hourly"

  validation {
    condition     = contains(["hourly", "daily"], var.partition_layout)
    error_message = "partition_layout must be \"hourly\" or \"daily\"."
  }
}

variable "projection_start_date" {
  description = "First date partition projection will consider, `yyyy-MM-dd`. Queries cannot see data delivered before this date, so set it at or before the date the delivery streams started writing partitioned keys."
  type        = string
  default     = "2025-01-01"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.projection_start_date))
    error_message = "projection_start_date must be formatted yyyy-MM-dd."
  }
}

# ── Schema behaviour ─────────────────────────────────────────────────────────

variable "case_insensitive_keys" {
  description = <<-EOT
    OpenX JSON SerDe `case.insensitive` setting.

    `false` (default) preserves key case and adds explicit `mapping.*` entries for osquery's
    camelCase top-level fields. `true` is simpler but lowercases keys *inside* maps as well,
    silently mangling mixed-case osquery column names, `SELECT x AS myColumn` aliases, and
    deployment-defined decoration keys, and collapsing keys that differ only in case.
  EOT
  type        = bool
  default     = false
}

variable "pack_delimiter" {
  description = "The `pack_delimiter` osquery agent option, used to split `pack<delim>{Global|team-<id>}<delim><query name>` in the views. Restricted to characters that are safe to embed in a regular expression."
  type        = string
  default     = "/"

  validation {
    condition     = contains(["/", "_", ":"], var.pack_delimiter)
    error_message = "pack_delimiter must be one of \"/\", \"_\", or \":\". Other delimiters would need escaping in the view regexes."
  }
}

variable "decoration_columns" {
  description = <<-EOT
    Decoration keys to project as top-level `decoration_<key>` columns in the results and status views.

    Decorations are deployment-defined: agent options can add, rename, or disable them entirely, so
    this module makes no assumption and defaults to none. Fleet's default agent options provide
    `host_uuid` and `hostname`, which most deployments will want here. The raw `decorations` map and
    `decorations_json` are always exposed regardless, and the decoration-discovery named query finds
    what a given environment actually emits.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for k in var.decoration_columns : can(regex("^[A-Za-z0-9_]+$", k))])
    error_message = "decoration_columns entries must contain only letters, digits, and underscores."
  }
}

variable "table_prefix" {
  description = "Optional prefix applied to every table and view name in the database, e.g. `staging_`."
  type        = string
  default     = ""
}

# ── Views ────────────────────────────────────────────────────────────────────

variable "example_named_queries" {
  description = "Save example analytic queries as Athena named queries, for discoverability in the console. These demonstrate the partition-widening pattern, decoration discovery, and a typed per-query view template; they create nothing."
  type        = bool
  default     = true
}

# ── Query results bucket / workgroup ─────────────────────────────────────────

variable "athena_database_force_destroy" {
  description = "Allow `terraform destroy` to delete the Athena database while it still contains tables. Defaults to false so supplementary views created by your team or by a modelling tool are not destroyed as collateral -- a destroy will fail instead, and you can drop them deliberately."
  type        = bool
  default     = false
}

variable "query_results_bucket_name" {
  description = "Name of the Athena query-results bucket. Defaults to `<prefix>-fleet-logs-athena`."
  type        = string
  default     = null
}

variable "query_results_expiration_days" {
  description = "Lifecycle expiration in days for Athena query results and metadata."
  type        = number
  default     = 30
}

variable "bytes_scanned_cutoff_per_query" {
  description = "Per-query data scanned limit enforced by the workgroup, in bytes. Guards against unpartitioned full-bucket scans. Set to null to disable. AWS requires at least 10 MB."
  type        = number
  default     = 10737418240 # 10 GiB

  validation {
    condition     = var.bytes_scanned_cutoff_per_query == null || var.bytes_scanned_cutoff_per_query >= 10485760
    error_message = "bytes_scanned_cutoff_per_query must be null or at least 10485760 (10 MB)."
  }
}

variable "s3_bucket_tags" {
  description = "Additional tags to apply to the S3 bucket created by this module."
  type        = map(string)
  default     = {}
}

variable "extra_s3_athena_policies" {
  description = "Extra bucket policy statements to attach to the query-results bucket."
  type        = list(any)
  default     = []
}

# ── Encryption ───────────────────────────────────────────────────────────────

variable "kms_key_arn" {
  description = "ARN of an existing KMS key to encrypt the query-results bucket and workgroup output. When null, this module creates one."
  type        = string
  default     = null
}

variable "source_kms_key_arns" {
  description = "ARNs of the CMKs encrypting the source log buckets. Required for the consumer role to read log data when the logging module is configured with `s3_kms_encryption_enabled = true`. Leave empty when the buckets use the AWS-managed S3 key."
  type        = list(string)
  default     = []
}

variable "kms_base_policy" {
  description = "Optional base KMS key-policy statements applied to the module-created CMK before module-required access statements are merged in. If null, the module defaults to the historical root `kms:*` statement."
  type = list(object({
    sid    = string
    effect = string
    principals = object({
      type        = string
      identifiers = list(string)
    })
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = null
}

variable "kms_extra_policies" {
  description = "Extra KMS key-policy statements for the module-created CMK. Only valid when this module creates the key (`kms_key_arn` is null)."
  type        = list(any)
  default     = []
}

# ── Consumer access ──────────────────────────────────────────────────────────

variable "consumer_role" {
  description = <<-EOT
    Read-only role for a third-party data modelling or BI application to assume as its Athena
    data connector.

    `trusted_principals` are the ARNs allowed to assume it (an account root such as
    `arn:aws:iam::111122223333:root`, or a specific role ARN). Set `external_id` to require
    `sts:ExternalId` on assumption, which vendors that support it should always be given.
  EOT
  type = object({
    enabled            = optional(bool, false)
    name               = optional(string, null)
    trusted_principals = optional(list(string), [])
    external_id        = optional(string, null)
    extra_policy_arns  = optional(list(string), [])
    max_session_hours  = optional(number, 1)
  })
  default = {}

  validation {
    condition     = !coalesce(var.consumer_role.enabled, false) || length(coalesce(var.consumer_role.trusted_principals, [])) > 0
    error_message = "consumer_role.trusted_principals must contain at least one ARN when consumer_role.enabled is true."
  }
}
