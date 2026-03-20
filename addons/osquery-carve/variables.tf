variable "osquery_carve_s3_bucket" {
  type = object({
    name         = optional(string, "fleet-osquery-results-archive")
    expires_days = optional(number, 1)
    kms = optional(object({
      kms_key_arn    = optional(string, null)
      create_kms_key = optional(bool, false)
      kms_alias      = optional(string, "osquery-carve")
      kms_base_policy = optional(list(object({
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
      })), null)
      extra_kms_policies = optional(list(any), [])
      fleet_role_arn     = optional(string, null)
      }), {
      kms_key_arn        = null
      create_kms_key     = false
      kms_alias          = "osquery-carve"
      kms_base_policy    = null
      extra_kms_policies = []
      fleet_role_arn     = null
    })
  })
  description = "Configuration for the osquery carve S3 bucket, including optional customer-managed KMS settings."
  default = {
    name         = "fleet-osquery-results-archive"
    expires_days = 1
    kms = {
      kms_key_arn        = null
      create_kms_key     = false
      kms_alias          = "osquery-carve"
      kms_base_policy    = null
      extra_kms_policies = []
      fleet_role_arn     = null
    }
  }

  validation {
    condition     = !(var.osquery_carve_s3_bucket.kms.kms_key_arn != null && var.osquery_carve_s3_bucket.kms.create_kms_key == true)
    error_message = "osquery_carve_s3_bucket.kms.kms_key_arn and osquery_carve_s3_bucket.kms.create_kms_key are mutually exclusive; set one or the other, not both."
  }

  validation {
    condition     = var.osquery_carve_s3_bucket.kms.create_kms_key == false || var.osquery_carve_s3_bucket.kms.fleet_role_arn != null || var.osquery_carve_s3_bucket.kms.kms_base_policy != null
    error_message = "osquery_carve_s3_bucket.kms.fleet_role_arn must be set when osquery_carve_s3_bucket.kms.create_kms_key is true and no kms_base_policy is provided."
  }
}
