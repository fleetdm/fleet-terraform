# Root-module interface for the per-service CMEK IAM propagation wait. The
# value is passed unchanged to ./byo-project, which owns the time_sleep (see
# byo-project/cmek-readiness.tf). Validated here too so invalid values fail at
# the root input rather than inside the child module.

variable "cmek_iam_propagation_delay_seconds" {
  description = <<-EOT
    Seconds to wait after the per-service CMEK KMS grants (cmek.cloud_sql,
    cmek.redis, cmek.cloud_run, cmek.secret_manager) before creating the
    resources that use those keys. Only applies when at least one of those
    consumers is set; 0 keeps the ordering but skips the wait. Default 120
    follows Google's typical IAM propagation time (about 2 minutes,
    https://docs.cloud.google.com/iam/docs/access-change-propagation); it is
    not a readiness guarantee.
  EOT
  type        = number
  default     = 120
  nullable    = false

  validation {
    condition = (
      var.cmek_iam_propagation_delay_seconds >= 0 &&
      floor(var.cmek_iam_propagation_delay_seconds) == var.cmek_iam_propagation_delay_seconds
    )
    error_message = "cmek_iam_propagation_delay_seconds must be a non-negative whole number of seconds (0 skips the wait)."
  }
}
