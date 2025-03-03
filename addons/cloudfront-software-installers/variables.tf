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
}
