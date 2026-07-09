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

variable "keypairs" {
  description = "Map of named keypairs for blue-green key rotation. Each value must contain `public_key` and `private_key`. When set, `public_key` and `private_key` variables are ignored."
  type = map(object({
    public_key  = string
    private_key = string
  }))
  default = null

  validation {
    condition     = var.keypairs != null || (var.public_key != null && var.private_key != null)
    error_message = "Either keypairs must be set, or both public_key and private_key must be provided."
  }

  validation {
    condition     = var.keypairs == null || var.key_group_id == null
    error_message = "keypairs cannot be used with key_group_id. Blue-green key rotation requires the module to manage the CloudFront key group."
  }
}

variable "active_keypair_name" {
  description = "Name of the keypair in `keypairs` (or `\"current\"` when using legacy inputs) whose keys populate the Secrets Manager secret. All keypairs in the map are added to the CloudFront key group so signed URLs from any retained key remain valid."
  type        = string
  default     = "current"

  validation {
    condition     = var.keypairs == null ? true : contains(keys(var.keypairs), var.active_keypair_name)
    error_message = "active_keypair_name must be a key present in the keypairs map."
  }
}

variable "private_key" {
  description = "Private key used for signed URLs. Deprecated: use `keypairs` instead."
  type        = string
  default     = null
}

variable "public_key" {
  description = "Public key used for signed URLs. Deprecated: use `keypairs` instead."
  type        = string
  default     = null
}

variable "s3_bucket" {
  description = "Name of the S3 bucket that Cloudfront will point to"
  type        = string
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
