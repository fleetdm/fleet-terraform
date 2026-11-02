# -----------------------------------------------------------------------------
# Bounded control-plane settlement checks after the restore PATCH.
#
# A single immediate read-back after the best-effort operations.wait can catch
# Cloud Run in a normal transient state: the PATCH was accepted, the desired
# fields (marker, AUTOMATIC/min) are already visible and the service generation
# has been bumped, while observedGeneration still trails it and the Ready
# condition is RECONCILING. Cloud Run normally settles that on its own a few
# seconds later; it is not a failed restore and must not need a second apply.
#
# This file adds a fixed, unrolled backoff of read-only GETs (base interval,
# 2x and 4x; defaults 30s + 60s + 120s = 210s, configurable for tests). Each
# wait is skipped when the preceding read already shows a settled control
# plane, or a terminal failure (waiting cannot heal it), so a healthy restore
# only performs as many GETs as needed. The existing
# data.terracurl_request.restore_verify stays the single final gate and still
# fails the apply (with one static, sensitivity-safe message) when the
# bounded window expires.
#
# Cardinality is static (count = local.migration_count): no count/for_each or
# timer duration depends on an API answer in a way that can loop. The timers
# are replaced only when this restore was actually (re)sent or the service
# itself was updated (replace_triggered_by), never on the service generation
# that the restore PATCH bumps itself. ignore_changes on create_duration keeps
# later no-op plans clean: a settled restore leaves stored durations that are
# not diffed against 0s.
#
# Provider-only: terracurl GETs and time_sleep. No local exec, gcloud, Python
# or polling daemon.
# -----------------------------------------------------------------------------

# First read: after the operation wait. This only observes the control plane;
# it does not fail the apply.
data "terracurl_request" "restore_probe_wait" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-probe-wait"
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
  # Control-plane settlement only (same fields as the final read-back). The
  # marker/AUTOMATIC/min checks are deliberately NOT part of the wait: a
  # restore that never applied is already settled and must fail fast in
  # restore_verify instead of waiting out the full backoff.
  settle_after_wait = var.migration_enabled ? try(jsondecode(data.terracurl_request.restore_probe_wait[0].response), null) : null
  settle_after_wait_skip = try(
    (
      alltrue([
        tostring(local.settle_after_wait.observedGeneration) == tostring(local.settle_after_wait.generation),
        !try(local.settle_after_wait.reconciling, false),
        local.settle_after_wait.terminalCondition.state == "CONDITION_SUCCEEDED",
        local.settle_after_wait.latestReadyRevision != "",
        local.settle_after_wait.latestReadyRevision == local.settle_after_wait.latestCreatedRevision,
      ]) ||
      (
        local.settle_after_wait.terminalCondition.state == "CONDITION_FAILED" &&
        !try(local.settle_after_wait.reconciling, false)
      )
    ),
    false,
  )
}

# Wait 1x the base interval, unless the first read already settled.
resource "time_sleep" "restore_settle_1" {
  count = local.migration_count

  create_duration = local.settle_after_wait_skip ? "0s" : "${var.restore_settle_interval_seconds}s"

  lifecycle {
    ignore_changes = [create_duration]
    # A new restore (the operation wait is replaced) or a service update opens
    # a fresh settlement window; a no-op plan touches neither and never waits.
    replace_triggered_by = [terracurl_request.restore_wait, google_cloud_run_v2_service.fleet]
  }
}

data "terracurl_request" "restore_probe_1" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-probe-1"
  url            = "${local.service_url}?fields=${urlencode(local.verify_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [time_sleep.restore_settle_1]
}

locals {
  settle_1 = var.migration_enabled ? try(jsondecode(data.terracurl_request.restore_probe_1[0].response), null) : null
  settle_1_skip = try(
    (
      alltrue([
        tostring(local.settle_1.observedGeneration) == tostring(local.settle_1.generation),
        !try(local.settle_1.reconciling, false),
        local.settle_1.terminalCondition.state == "CONDITION_SUCCEEDED",
        local.settle_1.latestReadyRevision != "",
        local.settle_1.latestReadyRevision == local.settle_1.latestCreatedRevision,
      ]) ||
      (
        local.settle_1.terminalCondition.state == "CONDITION_FAILED" &&
        !try(local.settle_1.reconciling, false)
      )
    ),
    false,
  )
}

# Wait 2x the base interval, unless the second read already settled.
resource "time_sleep" "restore_settle_2" {
  count = local.migration_count

  create_duration = local.settle_1_skip ? "0s" : "${var.restore_settle_interval_seconds * 2}s"

  lifecycle {
    ignore_changes       = [create_duration]
    replace_triggered_by = [terracurl_request.restore_wait, google_cloud_run_v2_service.fleet]
  }
}

data "terracurl_request" "restore_probe_2" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-probe-2"
  url            = "${local.service_url}?fields=${urlencode(local.verify_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [time_sleep.restore_settle_2]
}

locals {
  settle_2 = var.migration_enabled ? try(jsondecode(data.terracurl_request.restore_probe_2[0].response), null) : null
  settle_2_skip = try(
    (
      alltrue([
        tostring(local.settle_2.observedGeneration) == tostring(local.settle_2.generation),
        !try(local.settle_2.reconciling, false),
        local.settle_2.terminalCondition.state == "CONDITION_SUCCEEDED",
        local.settle_2.latestReadyRevision != "",
        local.settle_2.latestReadyRevision == local.settle_2.latestCreatedRevision,
      ]) ||
      (
        local.settle_2.terminalCondition.state == "CONDITION_FAILED" &&
        !try(local.settle_2.reconciling, false)
      )
    ),
    false,
  )
}

# Last wait (4x) before the final gate: data.terracurl_request.restore_verify
# in restore.tf reads the service once more and fails the apply when its
# postcondition still does not hold.
resource "time_sleep" "restore_settle_3" {
  count = local.migration_count

  create_duration = local.settle_2_skip ? "0s" : "${var.restore_settle_interval_seconds * 4}s"

  lifecycle {
    ignore_changes       = [create_duration]
    replace_triggered_by = [terracurl_request.restore_wait, google_cloud_run_v2_service.fleet]
  }
}
