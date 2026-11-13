variable "project_id" {
  description = "Project of the Fleet Cloud Run service and migration jobs."
  type        = string
}

variable "region" {
  description = "Cloud Run region."
  type        = string
}

variable "service_name" {
  description = "Fixed (literal) Cloud Run service name. The stop/restore REST calls address it by name, so it must not be derived from the service resource (that would be a cycle)."
  type        = string
  default     = "fleet-api"
}

variable "job_name_prefix" {
  description = "Prefix of the per-migration Cloud Run job names (<prefix>-<12 hex identity>[-<6 hex retry>])."
  type        = string
  default     = "fleet-migrate"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,24}$", var.job_name_prefix))
    error_message = "job_name_prefix must be 1-25 chars of [a-z0-9-] starting with a letter (job name + execution token must stay < 63 chars)."
  }
}

variable "image" {
  description = "Fleet container image (migration job and service). Part of the migration identity."
  type        = string
}

variable "service_account_email" {
  description = "Runtime service account of the service and the migration jobs."
  type        = string
}

variable "encryption_key" {
  description = "Optional Cloud Run CMEK key (null = Google-managed)."
  type        = string
  default     = null
}

variable "vpc_network" {
  description = "Direct VPC egress network."
  type        = string
}

variable "vpc_subnetwork" {
  description = "Direct VPC egress subnetwork."
  type        = string
}

variable "ingress" {
  description = "Service ingress."
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
}

variable "request_timeout" {
  description = "Service request timeout (stock Fleet: 300s)."
  type        = string
  default     = "300s"
}

variable "use_h2c" {
  description = "Serve h2c instead of http1 on the container port."
  type        = bool
  default     = false
}

variable "cpu" {
  description = "Container CPU limit."
  type        = string
}

variable "memory" {
  description = "Container memory limit. The stack keeps a 4096Mi floor (see validation)."
  type        = string

  validation {
    condition = (
      can(regex("^[0-9]+(Mi|Gi)$", var.memory)) &&
      (endswith(var.memory, "Gi") ? tonumber(trimsuffix(var.memory, "Gi")) * 1024 : tonumber(trimsuffix(var.memory, "Mi"))) >= 4096
    )
    error_message = "memory must be an Mi/Gi quantity of at least 4096Mi (Fleet memory floor)."
  }
}

variable "env" {
  description = "Plain container environment (service and migration job)."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Secret Manager environment references (service and migration job)."
  type = map(object({
    secret  = string
    version = string
  }))
  default = {}
}

variable "tmp_volume_config" {
  description = <<-EOT
    Disk-backed /tmp for the Fleet service container (not the migration job).
    enable = true (default) mounts one Cloud Run ephemeral disk volume
    (empty_dir, medium DISK, size_limit "<size_gib>Gi") at /tmp, so files
    written to /tmp no longer use instance memory. enable = false declares no
    volume and no mount: /tmp is the in-memory filesystem, as before.
    size_gib must be a whole number from 1 to 100 (Cloud Run ephemeral disk
    volume limits). Changes roll out as a new revision; they are not part of
    the migration identity and never trigger a migration.
  EOT
  type = object({
    enable   = optional(bool, true)
    size_gib = optional(number, 10)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      var.tmp_volume_config.size_gib >= 1 &&
      var.tmp_volume_config.size_gib <= 100 &&
      floor(var.tmp_volume_config.size_gib) == var.tmp_volume_config.size_gib
    )
    error_message = "tmp_volume_config.size_gib must be a whole number of GiB from 1 to 100."
  }
}

variable "min_instance_count" {
  description = "Service-level minimum instances restored after a verified migration."
  type        = number
}

variable "max_instance_count" {
  description = "Revision-level maximum instances."
  type        = number
}

variable "service_annotations" {
  description = "Extra service-level annotations. The module adds its own success marker and restore key (main.tf)."
  type        = map(string)
  default     = {}
}

variable "migration_enabled" {
  description = "When false no stop/job/restore objects exist and the service is always declared AUTOMATIC (operator runs migrations)."
  type        = bool
  default     = true
}

variable "database_identity" {
  description = <<-EOT
    Target database identity. Part of the migration identity: any change
    replaces terraform_data.identity (new UUID => new job name => one fresh
    migration). sql_connection_name should be the Cloud SQL instance's
    computed connection_name, which Terraform plans as unknown whenever the
    instance is (re)created, including a same-name ForceNew replacement.
  EOT
  type = object({
    sql_connection_name = string
    database_name       = string
  })
}

variable "migration_command" {
  description = "Migration job command."
  type        = list(string)
  default     = ["fleet"]
}

variable "migration_args" {
  description = "Migration job args."
  type        = list(string)
  default     = ["prepare", "db", "--no-prompt=true"]
}

variable "migration_task_timeout" {
  description = "Migration task timeout. The job create (and the apply) blocks up to this long; keep below the job create timeout."
  type        = string
  default     = "3600s"
}

variable "job_create_timeout" {
  description = "Terraform create timeout of the migration job (covers the whole run_execution_token execution)."
  type        = string
  default     = "75m"
}

variable "drain_seconds" {
  description = <<-EOT
    Bounded wait after the control plane reports MANUAL/0 and before the
    migration starts. Default 370 = stock 300s request timeout + 10s SIGTERM
    grace + 60s margin. This is a configurable wait, not a guarantee: Cloud Run
    documents no hard termination bound for instances after manual scaling to 0.
  EOT
  type        = number
  default     = 370

  validation {
    condition     = var.drain_seconds >= 0 && floor(var.drain_seconds) == var.drain_seconds
    error_message = "drain_seconds must be a non-negative integer."
  }
}

variable "operation_wait_seconds" {
  description = "Server-side operations.wait timeout used after the stop and restore PATCH (best effort; may return before done)."
  type        = number
  default     = 120
}

variable "restore_settle_interval_seconds" {
  description = <<-EOT
    Base interval of the bounded, read-only control-plane check after the
    restore PATCH: one probe, then at most one wait of 7x this interval
    (default 30 => 210s), skipped when the probe shows a settled service.
    Test fixtures shorten it; 0 keeps the checks but removes the wait.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.restore_settle_interval_seconds >= 0 && floor(var.restore_settle_interval_seconds) == var.restore_settle_interval_seconds
    error_message = "restore_settle_interval_seconds must be a non-negative integer."
  }
}

variable "run_api_base_url" {
  description = "Cloud Run Admin API v2 base URL used by the terracurl requests. Test fixtures point this (and the google-beta cloud_run_v2_custom_endpoint) at a loopback fake."
  type        = string
  default     = "https://run.googleapis.com/v2"
}

variable "prerequisites" {
  description = "Ordering-only values (IDs/etags of secrets, IAM grants, CMEK waits, database/user). The job and service wait for them; they never trigger a migration."
  type        = list(string)
  default     = []
}
