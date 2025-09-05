variable "customer" {
  description = "Customer name for the cloudfront instance"
  type        = string
  default     = "fleet"
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
