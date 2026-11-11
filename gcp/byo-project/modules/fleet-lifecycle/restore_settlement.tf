# -----------------------------------------------------------------------------
# Bounded control-plane settlement after the restore PATCH.
#
# Right after the restore, Cloud Run normally shows the desired fields (marker,
# AUTOMATIC/min) while observedGeneration still trails generation and Ready is
# RECONCILING; it settles on its own. That must not need a second apply.
#
# One read-only probe, then at most ONE wait of 7x restore_settle_interval_seconds
# (default 210s), skipped when the probe already shows a settled control plane
# or a terminal failure (waiting cannot heal it). An unsettled probe waits the
# full budget before the strict data.terracurl_request.restore_verify gate.
#
# The wait is replaced only when the restore was (re)sent or the service was
# updated, never on a no-op plan; ignore_changes on create_duration keeps later
# plans clean. Provider-only: a terracurl GET and a time_sleep.
# -----------------------------------------------------------------------------
data "terracurl_request" "restore_probe" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-probe"
  url            = "${local.service_url}?fields=${urlencode(local.verify_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [terracurl_request.restore_wait]
}

locals {
  # Control-plane state only: marker/AUTOMATIC/min are deliberately not part of
  # the skip, so a restore that never applied fails fast in restore_verify.
  settle_probe = var.migration_enabled ? try(jsondecode(data.terracurl_request.restore_probe[0].response), null) : null
  settle_skip = try(
    !try(local.settle_probe.reconciling, false) && (
      local.settle_probe.terminalCondition.state == "CONDITION_FAILED" || alltrue([
        tostring(local.settle_probe.observedGeneration) == tostring(local.settle_probe.generation),
        local.settle_probe.terminalCondition.state == "CONDITION_SUCCEEDED",
        local.settle_probe.latestReadyRevision != "",
        local.settle_probe.latestReadyRevision == local.settle_probe.latestCreatedRevision,
      ])
    ),
    false,
  )
}

resource "time_sleep" "restore_settle" {
  count = local.migration_count

  create_duration = local.settle_skip ? "0s" : "${var.restore_settle_interval_seconds * 7}s"

  lifecycle {
    ignore_changes       = [create_duration]
    replace_triggered_by = [terracurl_request.restore_wait, google_cloud_run_v2_service.fleet]
  }
}
