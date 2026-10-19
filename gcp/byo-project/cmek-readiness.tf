# -------------------------------------
# CMEK IAM propagation wait (per-service consumers only)
# -------------------------------------
# Granting a service agent roles/cloudkms.cryptoKeyEncrypterDecrypter (kms.tf)
# returns before the change is visible everywhere. Google documents that IAM
# access changes typically take about 2 minutes to propagate, and can take
# longer: https://docs.cloud.google.com/iam/docs/access-change-propagation
# Creating a CMEK-encrypted Cloud SQL instance, Memorystore instance, Cloud Run
# revision/job or Secret Manager secret immediately after the grant can
# therefore fail with a KMS permission error.
#
# One time_sleep runs after ALL opted-in per-service grants, and every opted-in
# consumer (database.tf, cache.tf, cloud_run.tf, secrets.tf) depends on it in
# addition to its direct grant. The wait is a best-effort delay, not a
# readiness guarantee.
#
# Created only when at least one of cmek.cloud_sql / redis / cloud_run /
# secret_manager is set. The count uses object presence (always known), never a
# key ID, so unknown key IDs stay plannable. Default and legacy GCS-only
# (cmek.enable) configurations have no time_sleep and no delay.
#
# The wait re-runs (time_sleep is replaced) when an opted-in grant's key, role
# or member changes, or when a consumer is added or removed. Changing only
# cmek_iam_propagation_delay_seconds updates create_duration in place without
# sleeping; the new duration applies on the next creation or trigger-driven
# replacement. Triggers deliberately exclude the grants' etag: the etag is the
# key's whole IAM policy etag, so it changes whenever any other binding on a
# shared key changes and would cause perpetual diffs.

variable "cmek_iam_propagation_delay_seconds" {
  description = <<-EOT
    Seconds to wait after the per-service CMEK KMS grants (cmek.cloud_sql,
    cmek.redis, cmek.cloud_run, cmek.secret_manager) before creating the
    resources that use those keys. Only applies when at least one of those
    consumers is set; 0 keeps the ordering but skips the wait. Default 120
    follows Google's typical IAM propagation time (about 2 minutes); it is not
    a readiness guarantee.
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

locals {
  # One entry per opted-in grant. Keys are known at plan time (from count /
  # for_each); values may be unknown until the key IDs are known. Built from
  # crypto_key_id, role and member only (see the etag note above).
  cmek_iam_propagation_triggers = merge(
    { for g in google_kms_crypto_key_iam_member.cloud_sql_cmek : "cloud_sql" => "${g.crypto_key_id}|${g.role}|${g.member}" },
    { for g in google_kms_crypto_key_iam_member.redis_cmek : "redis" => "${g.crypto_key_id}|${g.role}|${g.member}" },
    { for g in google_kms_crypto_key_iam_member.cloud_run_cmek : "cloud_run" => "${g.crypto_key_id}|${g.role}|${g.member}" },
    { for r, g in google_kms_crypto_key_iam_member.secret_manager_cmek : "secret_manager.${r}" => "${g.crypto_key_id}|${g.role}|${g.member}" },
  )
}

resource "time_sleep" "cmek_iam_propagation" {
  count = local.cmek_any_consumer ? 1 : 0

  create_duration = "${var.cmek_iam_propagation_delay_seconds}s"
  triggers        = local.cmek_iam_propagation_triggers

  depends_on = [
    google_kms_crypto_key_iam_member.cloud_sql_cmek,
    google_kms_crypto_key_iam_member.redis_cmek,
    google_kms_crypto_key_iam_member.cloud_run_cmek,
    google_kms_crypto_key_iam_member.secret_manager_cmek,
  ]
}
