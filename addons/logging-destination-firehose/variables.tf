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

variable "compression_format" {
  default = "UNCOMPRESSED"
}

variable "firehose_buffering_size" {
  description = "Firehose buffering size in MB. Set to null (default) to use the AWS default (4 MB)."
  type        = number
  default     = null
}

variable "firehose_buffering_interval" {
  description = "Firehose buffering interval in seconds. Set to null (default) to use the AWS default (60 s)."
  type        = number
  default     = null
}

variable "firehose_s3_prefix" {
  description = "S3 key prefix for Firehose delivery streams. Set to null (default) for no prefix."
  type        = string
  default     = null
}

variable "firehose_s3_error_output_prefix" {
  description = "S3 key prefix for Firehose error output. Set to null (default) for no error prefix."
  type        = string
  default     = null
}

variable "firehose_sse_enabled" {
  description = "Enable server-side encryption on Firehose delivery streams with a customer-managed KMS key."
  type        = bool
  default     = false
}

variable "s3_kms_encryption_enabled" {
  description = "Enable S3 server-side encryption with the customer-managed KMS key (same key used for Firehose SSE). When false, S3 uses the AWS-managed S3 key."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "ARN of an existing KMS key to use for Firehose SSE and S3 encryption. If not set and a key is needed (firehose_sse_enabled or s3_kms_encryption_enabled), a key is created automatically."
  type        = string
  default     = ""
}

variable "firehose_cloudwatch_logging_enabled" {
  description = "Enable CloudWatch logging for Firehose delivery streams. Creates log groups and grants logs:PutLogEvents permissions."
  type        = bool
  default     = false
}

variable "s3_bucket_key_enabled" {
  description = "Enable S3 bucket keys for server-side encryption to reduce KMS API costs. Set to false (default) to leave unchanged."
  type        = bool
  default     = false
}

variable "kms_base_policy" {
  description = "Base KMS key policy statements for the auto-created CMK. When null (default), a root-account kms:* statement is used. Only valid when the module creates the CMK (kms_key_arn is empty)."
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
  description = "Extra KMS key policy statements for the auto-created CMK. Only valid when the module creates the CMK (kms_key_arn is empty)."
  type        = any
  default     = []
}
