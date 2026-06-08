variable "prefix" {
  type    = string
  default = ""
}

variable "osquery_results_s3_bucket" {
  type = object({
    name         = optional(string, "fleet-osquery-results-archive")
    expires_days = optional(number, 1)
  })
  default = {
    name         = "fleet-osquery-results-archive"
    expires_days = 1
  }
}

variable "osquery_status_s3_bucket" {
  type = object({
    name         = optional(string, "fleet-osquery-status-archive")
    expires_days = optional(number, 1)
  })
  default = {
    name         = "fleet-osquery-status-archive"
    expires_days = 1
  }
}

variable "audit_s3_bucket" {
  type = object({
    name         = optional(string, "fleet-audit-archive")
    expires_days = optional(number, 1)
  })
  default = {
    name         = "fleet-audit-archive"
    expires_days = 1
  }
}

variable "attach_deny_insecure_transport_policy" {
  type        = bool
  default     = false
  description = "When true, attach a bucket policy to each S3 bucket that denies non-SSL requests."
}

variable "compression_format" {
  default = "UNCOMPRESSED"
}
