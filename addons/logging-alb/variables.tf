variable "prefix" {
  type    = string
  default = "fleet"
}

variable "alt_path_prefix" {
  description = "Used if the prefix inside of the s3 bucket doesn't match the name of the bucket prefix"
  type        = string
  default     = null
}

variable "enable_athena" {
  type    = bool
  default = true
}

variable "s3_transition_days" {
  type    = number
  default = 30
}

variable "s3_expiration_days" {
  type    = number
  default = 90
}

variable "s3_newer_noncurrent_versions" {
  type    = number
  default = 5
}

variable "s3_noncurrent_version_expiration_days" {
  type    = number
  default = 30
}

variable "lambda_log_retention_in_days" {
  description = "CloudWatch log retention in days for the re-encrypt and sweep Lambda functions"
  type        = number
  default     = 365
}

variable "extra_kms_policies" {
  type    = list(any)
  default = []
}

variable "kms_base_policy" {
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
  default     = null
  description = "Optional base KMS key-policy statements to apply to module-created CMKs before module-required service access statements are merged in. If null, the module defaults to the historical root `kms:*` statement."
}

variable "extra_s3_log_policies" {
  type    = list(any)
  default = []
}

variable "extra_s3_athena_policies" {
  type    = list(any)
  default = []
}
