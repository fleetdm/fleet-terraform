variable "customer" {
  description = "Customer name for the cloudfront instance"
  type        = string
  default     = "fleet"
}

variable "key_group_id" {
  description = "Cloudfront key group id"
  type        = string
  default     = null
}

variable "public_key_id" {
  description = "Cloudfront public key id. Required when passing in a key_group_id"
  type        = string
  default     = null

  validation {
    condition     = var.key_group_id == null || var.public_key_id != null
    error_message = "key_group_id provided. Please add a value for public_key_id."
  }

  validation {
    condition     = var.key_group_id != null || var.public_key_id == null
    error_message = "public_key_id provided. Please add a value for key_group_id."
  }
}

variable "private_key" {
  description = "Private key used for signed URLs"
  type        = string
}

variable "public_key" {
  description = "Public key used for signed URLs"
  type        = string
}

variable "s3_bucket" {
  description = "Name of the S3 bucket that Cloudfront will point to"
  type        = string
}

variable "s3_kms_key_id" {
  description = "KMS key id used to encrypt the s3 bucket"
  type        = string
  default     = null
}

variable "kms_policy" {
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
  description = "Optional base KMS key-policy statements to apply to the software-installers CMK before addon-required CloudFront access statements are merged in. If null, the addon defaults to the historical root `kms:*` statement."
}

variable "enable_logging" {
  description = "Enable optional logging to s3"
  type        = bool
  default     = false
}

variable "logging_s3_bucket" {
  description = "s3 bucket to log to"
  type        = string
  default     = null
}

variable "logging_s3_prefix" {
  description = "logging s3 bucket prefix"
  type        = string
  default     = "cloudfront"
}
