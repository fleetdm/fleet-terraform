# -----------------------------------------------------------------------------
# Restore: only after (a) the migration execution of this attempt reported
# EXECUTION_SUCCEEDED (gate on the service, service.tf) and (b) the provider deployed the target template while MANUAL/0 and the
# service reports that revision Ready. Then one REST PATCH sets AUTOMATIC/min
# and writes the success marker (identity UUID) and its restore key. Keyed on
# local.restore_key (normally the Job UID; never the service generation,
# which the PATCH itself bumps and would loop).
#
# HTTP 200 only means the PATCH was accepted: the LRO may still complete with
# an error, and a service can show the desired fields (marker, AUTOMATIC/min)
# while the control plane has not yet observed, or has failed to reconcile,
# that spec. A single immediate read is not enough either: a normal restore is
# transiently RECONCILING with observedGeneration trailing generation and
# settles on its own. restore_settlement.tf therefore reads the service once
# and, unless it is already settled (or terminally failed), waits once
# (default 210s); data.terracurl_request.restore_verify then reads it again and
# fails the apply unless the marker, AUTOMATIC/min AND a settled control plane
# (observedGeneration == generation, not reconciling, Ready succeeded, latest
# created revision ready) are visible. Plain retries converge without another
# migration:
#   * marker missing (LRO error): the next plan sees "attempt deployed and
#     settled but not restored" and plans a fresh restore key (main.tf), so a
#     plain apply re-sends the restore;
#   * marker present but not settled: the identity is already migrated
#     (`proven`; no stop, no job), the next apply re-checks settlement; if
#     the live service is still unsettled/failed the attempt nonce (main.tf)
#     deploys a fresh revision and the read-back is evaluated after it.
# No taint, no edits, no persistent failure on a managed request.
#
# The next plan reads the marker (data.terracurl_request.service_live), so
# local.serving becomes true and the service resource declares AUTOMATIC/min:
# no drift, no operator edits. The marker itself is not declared (see
# service.tf).
# -----------------------------------------------------------------------------

# Deferred token: read after the service step of this apply (the job may have
# run for up to an hour, longer than a plan-time token lives).
data "google_client_config" "restore" {
  provider   = google-beta
  depends_on = [google_cloud_run_v2_service.fleet]
}

locals {
  restore_body = jsonencode({
    scaling = {
      scalingMode      = "AUTOMATIC"
      minInstanceCount = var.min_instance_count
    }
    # updateMask=annotations replaces the whole map: re-send the live map read
    # right after the service step (the declared annotations as the provider
    # just applied them, plus out-of-band keys, the same merge the provider's
    # effective_annotations performs) with the marker and restore key on top.
    annotations = merge(try(local.ready.annotations, {}), {
      (local.marker_annotation_key)      = local.identity_id
      (local.restore_key_annotation_key) = local.restore_key
    })
  })
}

# Readiness of the service AFTER the service step of this apply. A data
# source (re-read every plan, deferred to apply while the service changes),
# because the provider keeps prior computed values (latest_*_revision,
# terminal_condition) in the plan of an in-place update: a precondition on
# the resource attributes was evaluated against stale values at plan time and
# blocked the redeploy retry (found in the loopback integration run, S7a).
data "terracurl_request" "service_ready" {
  count = local.migration_count

  name           = "fleet-lifecycle-service-ready"
  url            = "${local.service_url}?fields=${urlencode(local.ready_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [google_cloud_run_v2_service.fleet]
}

locals {
  ready_fields = "name,generation,observedGeneration,reconciling,terminalCondition(type,state,reason),latestReadyRevision,latestCreatedRevision,template(annotations),annotations"
  ready        = var.migration_enabled ? try(jsondecode(data.terracurl_request.service_ready[0].response), null) : null
}

resource "terracurl_request" "restore" {
  count = local.migration_count

  name   = "fleet-lifecycle-restore-${local.restore_key}"
  url    = "${local.service_url}?updateMask=scaling,annotations&fields=${urlencode(local.op_fields)}"
  method = "PATCH"
  # Annotations here are operator metadata only; no secrets.
  request_body = local.restore_body
  headers = {
    Authorization  = "Bearer ${data.google_client_config.restore.access_token}"
    "Content-Type" = "application/json"
  }
  response_codes = ["200"]
  timeout        = 60
  max_retry      = 2
  retry_interval = 10
  destroy_skip   = true

  lifecycle {
    # Only a new restore key (new job UID, or a detected failed restore) may
    # trigger a new restore; later min/annotation changes are applied by the
    # service resource itself.
    ignore_changes = [headers, url, method, request_body]

    # Migration success is gated on the service (service.tf), which this
    # restore follows.
    precondition {
      condition = local.proven || try(alltrue([
        local.ready.terminalCondition.state == "CONDITION_SUCCEEDED",
        local.ready.latestReadyRevision != "",
        local.ready.latestReadyRevision == local.ready.latestCreatedRevision,
        !try(local.ready.reconciling, false),
        tostring(local.ready.observedGeneration) == tostring(local.ready.generation),
        # Ownership = this attempt's Job UID on the deployed template (the
        # service and the job are configured from the same var.image).
        startswith(local.ready.template.annotations[local.attempt_annotation_key], local.job_uid),
      ]), false)
      error_message = "Refusing to restore Fleet: the target revision is not Ready (latest created != latest ready, failed terminal condition, still reconciling, or not this attempt). Fleet stays MANUAL/0, so the previous revision (old image on a migrated schema) is NOT restarted. Fix the rollout cause and run `terraform apply` again; a new revision is deployed automatically. Live status: ${try(jsonencode(local.ready), "unknown")}"
    }
  }
}

locals {
  restore_op   = try(jsondecode(terracurl_request.restore[0].response).name, "")
  restore_done = try(jsondecode(terracurl_request.restore[0].response).done, false)
}

# Best effort wait for the restore LRO (never treated as proof). Falls back to
# a read-only GET when there is nothing to wait on.
resource "terracurl_request" "restore_wait" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-wait-${local.restore_key}"
  url            = local.restore_op != "" && !local.restore_done ? "${local.run_api}/${local.restore_op}:wait?fields=${urlencode(local.op_fields)}" : local.service_get_url
  method         = local.restore_op != "" && !local.restore_done ? "POST" : "GET"
  request_body   = local.restore_op != "" && !local.restore_done ? jsonencode({ timeout = "${var.operation_wait_seconds}s" }) : null
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = var.operation_wait_seconds + 30
  max_retry      = 1
  retry_interval = 5
  destroy_skip   = true

  lifecycle {
    ignore_changes = [headers, url, method, request_body]
  }
}

# Read-back of the restore, after the bounded settlement checks in
# restore_settlement.tf. A data source: re-read every plan, deferred to apply
# whenever a restore or a service change is pending (so a failed restore never
# poisons later plans: the retry plan replaces restore_wait). Detects an LRO
# that answered HTTP 200 but completed with an error, a restore that otherwise
# did not take, and desired fields that the control plane has not (yet)
# settled: the apply fails instead of reporting success.
#
# The response itself is always validated, also for an already-proven
# identity (e.g. a proven identity's job re-created out of band gets a new
# restore key and re-sends the restore): no plan-time snapshot short-circuits
# it. On an ordinary no-op it is read at plan and shows the restored, settled
# service; whenever the live service is unsettled the attempt nonce plans a
# fresh revision, so the read is deferred until after that redeploy.
# Control-plane state only.
locals {
  verify_fields = "annotations,scaling,generation,observedGeneration,reconciling,terminalCondition(type,state,reason),latestReadyRevision,latestCreatedRevision"
}

data "terracurl_request" "restore_verify" {
  count = local.migration_count

  name           = "fleet-lifecycle-restore-verify"
  url            = "${local.service_url}?fields=${urlencode(local.verify_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.restore.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [time_sleep.restore_settle, terracurl_request.restore_wait, google_cloud_run_v2_service.fleet]

  lifecycle {
    postcondition {
      condition = try(alltrue([
        jsondecode(self.response).annotations[local.marker_annotation_key] == local.identity_id,
        jsondecode(self.response).scaling.scalingMode == "AUTOMATIC",
        tonumber(try(jsondecode(self.response).scaling.minInstanceCount, 0)) == var.min_instance_count,
        tostring(jsondecode(self.response).observedGeneration) == tostring(jsondecode(self.response).generation),
        !try(jsondecode(self.response).reconciling, false),
        jsondecode(self.response).terminalCondition.state == "CONDITION_SUCCEEDED",
        jsondecode(self.response).latestReadyRevision != "",
        jsondecode(self.response).latestReadyRevision == jsondecode(self.response).latestCreatedRevision,
      ]), false)
      # STATIC on purpose: a caller may pass min_instance_count from a
      # sensitive whole-config object (the GCP root does), and interpolating
      # it (or the raw response) here would make Terraform reject this very
      # diagnostic with "Error message refers to sensitive values". No live
      # value is included, so neither a success nor a failure depends on
      # sensitivity marks or declassifies anything.
      error_message = "Restore did not take effect or has not settled within the bounded control-plane checks: the service must show the migration marker, AUTOMATIC scaling with the configured minimum, observedGeneration == generation, reconciling=false, a succeeded Ready condition and latest created == latest ready revision. The PATCH being accepted (or the best-effort operation wait returning) is not completion. Run `terraform apply` again: the migration does not re-run; the restore is re-sent if its marker is missing, and a still-unsettled service gets a fresh revision of this attempt."
    }
  }
}
