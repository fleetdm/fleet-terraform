# -----------------------------------------------------------------------------
# Fleet migration lifecycle: identity, plan-time status reads, shared locals
#
# Apply-path order for a NEW migration identity (all native):
#   identity -> attempt -> execution inventory GET (no earlier relevant
#   migration execution may still be active) -> stop PATCH (MANUAL/0 +
#   LATEST/100 untagged) -> operations.wait (best effort) -> verify GET
#   (MANUAL/0, not reconciling, observedGeneration == generation, no traffic
#   tags) -> bounded drain
#   -> Job CREATE with run_execution_token (provider waits for the execution)
#   -> Service update/create still MANUAL/0 with the target template
#      (provider waits for the Ready revision)
#   -> restore PATCH (AUTOMATIC/min + success marker = identity UUID)
#   -> bounded, read-only control-plane settlement checks (restore_settlement.tf)
#   -> restore read-back: marker + AUTOMATIC/min AND a settled control plane.
#
# Image contract: var.image (the caller's literal fleet_config.image_tag, e.g.
# "fleetdm/fleet:v4.93.0") is the ONLY image identity. Job and service are
# configured from that same string. A changed string triggers one migration;
# an unchanged string does not itself trigger one (initial deployment, database
# changes and failure retries can still do so). Nothing here reads,
# compares, resolves or validates the image the Cloud Run API reports (no
# registry lookups, digests or tag policy): ownership of a deployed revision is
# the attempt annotation (Job UID) plus the Ready checks. Re-pushing different
# contents behind an unchanged tag is accepted and not detected.
#
# Resource cardinality is static (count only from var.migration_enabled).
# Nothing here uses provisioners, scripts, gcloud, ADC or local commands.
# -----------------------------------------------------------------------------

locals {
  migration_count = var.migration_enabled ? 1 : 0

  run_api        = trimsuffix(var.run_api_base_url, "/")
  parent         = "projects/${var.project_id}/locations/${var.region}"
  service_path   = "${local.parent}/services/${var.service_name}"
  service_url    = "${local.run_api}/${local.service_path}"
  identity_label = "fleetdm-lifecycle-identity"

  # Google partial-response masks (standard `fields` system parameter).
  # They keep the non-sensitive terracurl `response` attribute metadata-only:
  # no container env, license key or template body is copied into state.
  # ASSUMPTION (not verified against live Cloud Run): the Run v2 REST surface
  # honours `fields` like other Google JSON APIs. The local fake enforces it.
  # No container image is requested anywhere (see the image contract above).
  service_fields  = "name,uid,generation,observedGeneration,reconciling,annotations,scaling,traffic,trafficStatuses,terminalCondition(type,state,reason),latestReadyRevision,latestCreatedRevision,template(annotations)"
  job_list_fields = "jobs(name,uid,labels,reconciling,terminalCondition(type,state,reason)),nextPageToken"
  op_fields       = "name,done,error(code,message)"
  # Every execution of every job in this project/region ("-" = all jobs; the
  # region stays fixed). Documented for projects.locations.jobs.executions.list
  # (needs run.executions.list, included in roles/run.admin).
  exec_list_fields = "executions(name,job,createTime,startTime,completionTime,deleteTime,reconciling,runningCount,conditions(type,state,reason)),nextPageToken"

  service_get_url = "${local.service_url}?fields=${urlencode(local.service_fields)}"
  jobs_list_url   = "${local.run_api}/${local.parent}/jobs?pageSize=1000&fields=${urlencode(local.job_list_fields)}"
  exec_list_url   = "${local.run_api}/${local.parent}/jobs/-/executions?pageSize=1000&fields=${urlencode(local.exec_list_fields)}"

  # Job IDs whose executions are Fleet migrations: the fixed-name job of
  # earlier releases (forgotten via `removed`, possibly still present) and
  # every per-identity job of this module (all identities, including orphans
  # outside state). Labels are deliberately not used.
  legacy_job_id = "fleet-migration"
}

# Access tokens come from the SAME google-beta provider configuration that
# manages the service and jobs (no gcloud, no ADC subprocess). The token is a
# short-lived (~1h) OAuth token. It is kept in sensitive expressions, but it is
# still persisted in plaintext in plan files and state (terracurl `headers`).
data "google_client_config" "plan" {
  provider = google-beta
}

# -----------------------------------------------------------------------------
# Migration identity. A new UUID (unknown at plan) whenever one of these
# changes => new job name => exactly one fresh migration attempt.
# sql_connection_name is computed-only and planned unknown when the instance is
# created/replaced, so a same-name Cloud SQL replacement also yields a new
# identity even if the final connection_name string is identical.
# -----------------------------------------------------------------------------
resource "terraform_data" "identity" {
  count = local.migration_count

  triggers_replace = {
    image               = var.image
    project             = var.project_id
    region              = var.region
    service             = var.service_name
    sql_connection_name = var.database_identity.sql_connection_name
    database            = var.database_identity.database_name
  }
}

# Ordering-only fan-in for secrets/IAM/CMEK/database prerequisites.
resource "terraform_data" "prerequisites" {
  input = var.prerequisites
}

# -----------------------------------------------------------------------------
# Plan-time, read-only status (metadata-only partial responses).
# -----------------------------------------------------------------------------
data "terracurl_request" "service_live" {
  count = local.migration_count

  name           = "fleet-lifecycle-service-live"
  url            = local.service_get_url
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.plan.access_token}" }
  response_codes = ["200", "404"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 5
}

data "terracurl_request" "jobs_live" {
  count = local.migration_count

  name           = "fleet-lifecycle-jobs-live"
  url            = local.jobs_list_url
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.plan.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 5
}

locals {
  identity_id  = var.migration_enabled ? terraform_data.identity[0].id : ""
  identity_hex = substr(replace(local.identity_id, "-", ""), 0, 12)

  svc_found = var.migration_enabled && try(data.terracurl_request.service_live[0].status_code, "") == "200"
  svc       = local.svc_found ? try(jsondecode(data.terracurl_request.service_live[0].response), null) : null

  # Success marker written ONLY by the restore PATCH after a verified job and a
  # Ready target revision. Value = identity UUID. It is derived state, not a
  # lock or checkpoint; nobody edits it.
  live_marker = try(tostring(local.svc.annotations[var.marker_annotation_key]), "")

  # True only when the live service already proves THIS identity was migrated
  # and restored. Unknown at plan while the identity is being replaced.
  proven = var.migration_enabled && local.live_marker != "" && local.live_marker == local.identity_id

  # Declared scaling: MANUAL/0 until the current identity is proven restored.
  # `proven` means "this identity's migration already succeeded" (the marker is
  # only written after a successful job). It never depends on the live health
  # of the service: a later unhealthy service must not stop Fleet or re-run
  # the migration. Restore SETTLEMENT is checked separately (live_settled
  # below and data.terracurl_request.restore_verify).
  serving = !var.migration_enabled || local.proven

  # Control plane settled on the live service: the latest spec generation is
  # observed, nothing is reconciling, the Ready condition succeeded and the
  # latest created revision is the ready one. Control-plane readiness only,
  # not proof about individual instances.
  live_settled = try(alltrue([
    tostring(local.svc.observedGeneration) == tostring(local.svc.generation),
    !try(local.svc.reconciling, false),
    local.svc.terminalCondition.state == "CONDITION_SUCCEEDED",
    local.svc.latestReadyRevision != "",
    local.svc.latestReadyRevision == local.svc.latestCreatedRevision,
  ]), false)

  # Jobs of the current identity (label written at job create).
  jobs_page       = var.migration_enabled ? try(jsondecode(data.terracurl_request.jobs_live[0].response), null) : null
  jobs_truncated  = try(local.jobs_page.nextPageToken, "") != ""
  identity_jobs   = [for j in try(local.jobs_page.jobs, []) : j if try(j.labels[local.identity_label], "") == local.identity_hex]
  current_job     = length(local.identity_jobs) == 1 ? local.identity_jobs[0] : null
  current_job_tc  = try(local.current_job.terminalCondition.state, "")
  current_failed  = local.current_job != null && local.current_job_tc == "CONDITION_FAILED"
  job_base_name   = "${var.job_name_prefix}-${local.identity_hex}"
  current_job_uid = try(local.current_job.uid, "")

  # Retry without taint/checkpoint: a live FAILED job of this identity yields
  # a new deterministic name (=> replacement => fresh execution with CURRENT
  # config). Otherwise keep the live/base name (no churn on no-op).
  job_name = (
    local.current_job == null ? local.job_base_name :
    local.current_failed ? "${local.job_base_name}-${substr(sha256(local.current_job_uid), 0, 6)}" :
    # the API returns full resource names: keep only the job ID
    try(reverse(split("/", local.current_job.name))[0], local.job_base_name)
  )

  # Revision-template attempt annotation. Base value = Job UID (new per job,
  # including a same-name tainted re-create). If the live service shows this
  # attempt's rollout did not become Ready, append a hash of the latest created
  # revision so the next plain apply deploys a fresh revision instead of
  # leaving a failed rollout silently in place.
  live_attempt   = try(tostring(local.svc.template.annotations[var.attempt_annotation_key]), "")
  live_healthy   = local.live_settled
  job_uid        = var.migration_enabled ? google_cloud_run_v2_job.migration[0].uid : ""
  attempt_is_cur = local.live_attempt != "" && startswith(local.live_attempt, local.job_uid)
  attempt_value = (
    !local.attempt_is_cur ? local.job_uid :
    local.live_healthy ? local.live_attempt :
    "${local.job_uid}.${substr(sha256(try(local.svc.latestCreatedRevision, "")), 0, 8)}"
  )

  # Restore key (see restore.tf). The restore PATCH writes it into a service
  # annotation together with the marker. If the live service shows THIS
  # attempt (Job UID annotation) deployed and settled but the identity is not
  # proven restored (e.g. the restore LRO completed with an error), the next
  # plan uses a fresh key (timestamp => unknown at plan) so a plain apply
  # re-sends the restore. After success the key is read back from the live
  # annotation, so plans stay clean. The image reported by the API plays no
  # part (it may be resolved, aliased or omitted).
  live_restore_key = try(tostring(local.svc.annotations[var.restore_key_annotation_key]), "")
  restore_needed   = var.migration_enabled && !local.proven && local.attempt_is_cur && local.live_healthy
  restore_key = (
    local.restore_needed ? "${local.job_uid}-r${formatdate("YYMMDDhhmmss", timestamp())}" :
    local.live_restore_key != "" && startswith(local.live_restore_key, local.job_uid) ? local.live_restore_key :
    local.job_uid
  )
}
