# -----------------------------------------------------------------------------
# Attempt + stop + control-plane verification + bounded drain.
# -----------------------------------------------------------------------------

# One attempt per job name. A new identity or a live failed job/execution of
# the current identity changes the job name, which re-runs stop/verify/drain
# before the new job. A tainted job that keeps its name reuses the existing
# attempt: Fleet was already stopped by it, and verify (a data source)
# re-checks the live state.
resource "terraform_data" "attempt" {
  count = local.migration_count

  triggers_replace = {
    job_name = local.job_name
  }
}

# Deferred token: read during apply whenever a new attempt is being created
# (depends_on a resource with pending changes), so the stop/verify requests do
# not carry a token minted at plan time.
data "google_client_config" "attempt" {
  provider   = google-beta
  depends_on = [terraform_data.attempt]
}

locals {
  attempt_auth = {
    Authorization  = "Bearer ${data.google_client_config.attempt.access_token}"
    "Content-Type" = "application/json"
  }

  # Stop body: scaling AND traffic, so out-of-band traffic tags (which Google
  # documents keep tagged revisions reachable despite MANUAL/0) are removed
  # before any migration. Removing tags is an intentional side effect of the stop.
  stop_body = jsonencode({
    scaling = {
      scalingMode         = "MANUAL"
      manualInstanceCount = 0
      minInstanceCount    = 0
    }
    traffic = [{
      type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
      percent = 100
    }]
  })
}

# Stop Fleet: PATCH services/<literal name>?updateMask=scaling,traffic.
# 200 = accepted (an LRO, NOT proof of completion); 404 = fresh deployment
# (no service yet). 401/403/5xx are never treated as absence: terracurl
# retries (PATCH with a fixed body is idempotent) then fails the apply; the
# create error leaves this resource tainted so the next apply re-sends it.
# When the identity is already migrated (`migrated` in main.tf; e.g. the job
# was only re-created after an out-of-band delete) this degrades to a
# read-only GET so a no-op can never stop Fleet.
resource "terracurl_request" "stop" {
  count = local.migration_count

  name           = "fleet-lifecycle-stop-${terraform_data.attempt[0].id}"
  url            = local.migrated ? local.service_get_url : "${local.service_url}?updateMask=scaling,traffic&fields=${urlencode(local.op_fields)}"
  method         = local.migrated ? "GET" : "PATCH"
  request_body   = local.migrated ? null : local.stop_body
  headers        = local.attempt_auth
  response_codes = ["200", "404"]
  timeout        = 60
  max_retry      = 2
  retry_interval = 10
  destroy_skip   = true

  lifecycle {
    # Request fields are ForceNew in terracurl 1.2.2. Only `name` (the attempt)
    # may trigger a new request; token refreshes or a later proven/AUTO view
    # must not re-send the stop.
    ignore_changes = [headers, url, method, request_body]
  }
}

locals {
  stop_status = var.migration_enabled ? terracurl_request.stop[0].status_code : ""
  stop_op     = try(jsondecode(terracurl_request.stop[0].response).name, "")
  stop_done   = try(jsondecode(terracurl_request.stop[0].response).done, false)
  stop_waits  = var.migration_enabled && !local.migrated && local.stop_status == "200" && local.stop_op != "" && !local.stop_done
}

# Best effort: operations.wait returns when the LRO is done OR when the
# server-side timeout elapses (Google documents it may return early). It is
# never treated as proof; verify below is the gate. When there is nothing to
# wait on it performs the same read-only service GET instead (static count).
# Replaced together with the stop (replace_triggered_by), so a re-sent stop
# (e.g. `-replace` of the stop, or a tainted stop) waits on ITS operation,
# not on the cached operation of the earlier stop.
resource "terracurl_request" "stop_wait" {
  count = local.migration_count

  name           = "fleet-lifecycle-stop-wait-${terraform_data.attempt[0].id}"
  url            = local.stop_waits ? "${local.run_api}/${local.stop_op}:wait?fields=${urlencode(local.op_fields)}" : local.service_get_url
  method         = local.stop_waits ? "POST" : "GET"
  request_body   = local.stop_waits ? jsonencode({ timeout = "${var.operation_wait_seconds}s" }) : null
  headers        = local.attempt_auth
  response_codes = ["200", "404"]
  timeout        = var.operation_wait_seconds + 30
  max_retry      = 1
  retry_interval = 5
  destroy_skip   = true

  lifecycle {
    ignore_changes       = [headers, url, method, request_body]
    replace_triggered_by = [terracurl_request.stop]
  }
}

# Control-plane verification. A data source, so it is re-read on every plan:
# a transient failure (still reconciling) never strands state; the next plain
# apply re-checks. Read during apply when a new attempt is in progress.
# MANUAL/0 + reconciling=false + observedGeneration==generation is
# control-plane readiness only, NOT proof that zero instances are running.
data "terracurl_request" "stop_verify" {
  count = local.migration_count

  name           = "fleet-lifecycle-stop-verify"
  url            = local.service_get_url
  method         = "GET"
  headers        = local.attempt_auth
  response_codes = ["200", "404"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [terracurl_request.stop_wait]

  lifecycle {
    postcondition {
      condition = (
        local.migrated ||
        (self.status_code == "404" && local.stop_status == "404") ||
        (self.status_code == "200" && try(alltrue([
          jsondecode(self.response).scaling.scalingMode == "MANUAL",
          tonumber(try(jsondecode(self.response).scaling.manualInstanceCount, 0)) == 0,
          tonumber(try(jsondecode(self.response).scaling.minInstanceCount, 0)) == 0,
          !try(jsondecode(self.response).reconciling, false),
          tostring(try(jsondecode(self.response).observedGeneration, "?")) == tostring(try(jsondecode(self.response).generation, "!")),
          length(try(jsondecode(self.response).traffic, [])) == 1,
          alltrue([for t in try(jsondecode(self.response).traffic, []) : try(t.tag, "") == "" && try(t.type, "") == "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST" && tonumber(try(t.percent, 0)) == 100]),
          alltrue([for t in try(jsondecode(self.response).trafficStatuses, []) : try(t.tag, "") == ""]),
        ]), false))
      )
      error_message = "Fleet is not verifiably stopped (control plane): need MANUAL/0, reconciling=false, observedGeneration==generation, exactly LATEST/100 traffic and no traffic tags (tagged revisions stay reachable under MANUAL/0). No migration was started. Status ${self.status_code}: ${self.response}. Wait for reconciliation and re-run `terraform apply`; if scaling/traffic was changed by hand after a failed attempt, a plain re-apply stays blocked: fix the live service or re-send the stop with `terraform apply -replace` of this module's terracurl_request.stop[0] (the operation wait and the bounded drain are then repeated before any migration)."
    }
  }
}

# Bounded drain after the control plane reports MANUAL/0. Skipped for a fresh
# deployment (404) and for an already-migrated identity. A configurable wait,
# not a guarantee (no documented hard termination bound).
# Keyed on the attempt AND replaced whenever the stop itself is (re)created
# (replace_triggered_by): a fresh stop (e.g. after Fleet was restarted out of
# band and the stop is re-sent with `-replace`) is followed by a fresh drain
# before any further migration, even when the attempt, the job name or the
# stop's final ID are unchanged. A no-op plan never touches the stop, so it
# never re-triggers the drain.
resource "time_sleep" "drain" {
  count = local.migration_count

  create_duration = (local.migrated || local.stop_status == "404") ? "0s" : "${var.drain_seconds}s"

  triggers = {
    attempt = terraform_data.attempt[0].id
  }

  lifecycle {
    ignore_changes       = [create_duration]
    replace_triggered_by = [terracurl_request.stop]
  }

  depends_on = [data.terracurl_request.stop_verify]
}
