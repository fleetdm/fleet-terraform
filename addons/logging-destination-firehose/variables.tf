variable "prefix" {
  type    = string
  default = ""
}

variable "s3_bucket_name" {
  description = "Base name for S3 buckets. When consolidate_to_single_bucket is false (default), each bucket name defaults to '<s3_bucket_name>-<key>' unless overridden by bucket_name in log_destinations. When true, this is the single shared bucket name."
  type        = string
  default     = "fleet-osquery-logging-archive"
}

variable "s3_force_destroy" {
  description = "Whether to allow the S3 bucket(s) to be destroyed even if they contain objects."
  type        = bool
  default     = false
}

variable "s3_lifecycle_expires_days" {
  description = "Default number of days after which objects in the S3 bucket(s) expire. Set to 0 to disable lifecycle expiration. Can be overridden per-destination via log_destinations[*].lifecycle_expires_days."
  type        = number
  default     = 0
}

variable "server_side_encryption_enabled" {
  description = "Enable server-side encryption on the Firehose delivery streams and S3 bucket(s)."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "An optional KMS key ARN for server-side encryption. If not provided and encryption is enabled, a new key will be created."
  type        = string
  default     = ""
}

variable "consolidate_to_single_bucket" {
  description = "When true, all log types share a single S3 bucket partitioned by prefix. When false (default), each log type gets its own S3 bucket. Default false preserves the legacy 3-bucket layout for seamless migration."
  type        = bool
  default     = false
}

variable "fleet_firehose_result_stream_key" {
  description = "The key in var.log_destinations that provides the osquery results stream. Must match a key in log_destinations."
  type        = string
  default     = "results"
}

variable "fleet_firehose_status_stream_key" {
  description = "The key in var.log_destinations that provides the osquery status stream. Must match a key in log_destinations."
  type        = string
  default     = "status"
}

variable "fleet_firehose_audit_stream_key" {
  description = "The key in var.log_destinations that provides the audit stream. Must match a key in log_destinations."
  type        = string
  default     = "audit"
}

variable "log_destinations" {
  description = "A map of configurations for Firehose delivery streams."
  type = map(object({
    name                    = string
    bucket_name             = optional(string, null)
    lifecycle_expires_days  = optional(number, null)
    prefix                  = string
    error_output_prefix     = string
    buffering_size          = number
    buffering_interval      = number
    compression_format      = string
  }))
  default = {
    results = {
      name                    = "osquery_results"
      bucket_name             = null
      lifecycle_expires_days  = null
      prefix                  = "results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "results/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
    status = {
      name                    = "osquery_status"
      bucket_name             = null
      lifecycle_expires_days  = null
      prefix                  = "status/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "status/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
    audit = {
      name                    = "fleet_audit"
      bucket_name             = null
      lifecycle_expires_days  = null
      prefix                  = "audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "audit/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
  }

  validation {
    condition     = contains(keys(var.log_destinations), var.fleet_firehose_result_stream_key)
    error_message = "The fleet_firehose_result_stream_key must be a key present in log_destinations."
  }

  validation {
    condition     = contains(keys(var.log_destinations), var.fleet_firehose_status_stream_key)
    error_message = "The fleet_firehose_status_stream_key must be a key present in log_destinations."
  }

  validation {
    condition     = contains(keys(var.log_destinations), var.fleet_firehose_audit_stream_key)
    error_message = "The fleet_firehose_audit_stream_key must be a key present in log_destinations."
  }
}
