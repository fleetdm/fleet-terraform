variable "software_installers_config" {
  description = <<-EOT
    Object versioning and noncurrent-version retention for the software
    installers bucket (fleet_config.installers_bucket_name). Matches the AWS
    module defaults:

      enable_bucket_versioning           - Turn on GCS object versioning
                                           (default false).
      expire_noncurrent_versions         - When versioning is on, delete
                                           noncurrent (overwritten or deleted)
                                           object versions after
                                           noncurrent_version_expiration_days
                                           (default true). Set false to keep
                                           every noncurrent version.
      noncurrent_version_expiration_days - Days a version must have been
                                           noncurrent before it is deleted
                                           (default 30). Must be a positive
                                           whole number.

    The expiry rule only matches noncurrent versions; live objects are never
    deleted by it. With versioning off no lifecycle rule is created. Turning
    versioning off on an existing versioned bucket suspends versioning but
    does not delete versions already stored.
  EOT
  type = object({
    enable_bucket_versioning           = optional(bool, false)
    expire_noncurrent_versions         = optional(bool, true)
    noncurrent_version_expiration_days = optional(number, 30)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      var.software_installers_config.noncurrent_version_expiration_days >= 1 &&
      floor(var.software_installers_config.noncurrent_version_expiration_days) == var.software_installers_config.noncurrent_version_expiration_days
    )
    error_message = "software_installers_config.noncurrent_version_expiration_days must be a positive whole number of days (1 or more)."
  }
}

locals {
  # Only expire noncurrent versions when versioning is on, mirroring the AWS
  # module, which gates its noncurrent-version lifecycle rule on versioning.
  software_installers_expire_noncurrent = (
    var.software_installers_config.enable_bucket_versioning &&
    var.software_installers_config.expire_noncurrent_versions
  )
}
