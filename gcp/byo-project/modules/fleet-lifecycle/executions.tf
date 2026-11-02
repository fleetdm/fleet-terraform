# -----------------------------------------------------------------------------
# Earlier-migration guard: no NEW migration execution starts while an earlier
# Fleet migration execution is observably still active.
#
# Inventory: ONE list of every execution of every job in this project/region
# (`jobs/-/executions`), not only the latest execution of the current job, so
# an older still-running execution is found even when a newer execution of
# the same job already completed. Relevant job IDs (local.legacy_job_id and
# "<job_name_prefix>-*", every identity including orphans outside state) are
# taken from Execution.job (short or full name) or, failing that, from
# Execution.name (.../jobs/<job>/executions/<execution>). Labels are not
# trusted. Executions of unrelated jobs never block.
#
# Settled = non-empty completionTime AND runningCount == 0 (an omitted
# runningCount is proto3 zero). Anything else (pending, running, cancelling,
# missing completionTime) is active.
#
# Timing: the read depends on terraform_data.attempt, so
#   * a NEW attempt (new identity, or a FAILED job's retry name) reads it
#     during apply, right after the attempt and BEFORE the stop PATCH: the
#     stop precondition fails and Fleet is not even stopped;
#   * otherwise (e.g. a tainted or `-replace`d job keeping its name, or a
#     retry after a failed verify or a failed rollout) it is read at plan and the job precondition fails the
#     PLAN, so Terraform never deletes a tainted job whose execution is still
#     running.
# Known ordering limit of the apply-time read: for a new identity Terraform
# may delete the PREVIOUS identity's managed job (first half of the job
# replacement) before the guard fails; Cloud Run documents that deleting a job
# terminates its executions. Earlier jobs outside state are never touched.
# A clear failure, nothing else: the guard never deletes, cancels or adopts
# unmanaged/orphan/legacy jobs. Re-run `terraform apply` after the earlier
# execution has finished. This is control-plane state only, not proof that
# no container is still running (Cloud Run documents that deleting a job
# terminates its executions; that is not re-verified here).
#
# Only a 200 list counts as an inventory: other statuses fail the request
# (response_codes), and an unparsable body or a nextPageToken (more than 1000
# executions; no partial inventory is claimed) fails the guard. An omitted
# `executions` array in a valid 200 body is a legitimately empty region.
# -----------------------------------------------------------------------------
data "terracurl_request" "executions_live" {
  count = local.migration_count

  name           = "fleet-lifecycle-executions-live"
  url            = local.exec_list_url
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.attempt.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 5

  depends_on = [terraform_data.attempt]
}

locals {
  exec_status = var.migration_enabled ? try(data.terracurl_request.executions_live[0].status_code, "") : ""
  exec_page   = var.migration_enabled ? try(jsondecode(data.terracurl_request.executions_live[0].response), null) : null

  # A JSON object whose `executions` (when present) is an array.
  exec_parsed = (
    local.exec_status == "200" &&
    can(keys(local.exec_page)) &&
    can(concat(try(local.exec_page.executions, []), []))
  )
  exec_truncated = try(length(local.exec_page.nextPageToken) > 0, false)
  exec_valid     = local.exec_parsed && !local.exec_truncated

  exec_items = [
    # No conditional here: tuples of different lengths do not unify. Entries
    # only matter when exec_parsed (exec_valid gates the guard anyway).
    for e in try(concat(local.exec_page.executions, []), []) : {
      name = try(tostring(e.name), "")
      job = (
        try(regex("([^/]+)$", tostring(e.job))[0], "") != "" ?
        try(regex("([^/]+)$", tostring(e.job))[0], "") :
        try(regex("/jobs/([^/]+)/executions/[^/]+$", tostring(e.name))[0], "")
      )
      settled = try(length(e.completionTime) > 0, false) && try(coalesce(tonumber(e.runningCount), 0), 0) == 0
    }
  ]

  # Entries that cannot be attributed to a job are treated as blocking.
  exec_relevant = [
    for e in local.exec_items : e
    if e.job == "" || e.job == local.legacy_job_id || startswith(e.job, "${var.job_name_prefix}-")
  ]
  exec_active = [for e in local.exec_relevant : e.name != "" ? e.name : "(unnamed execution)" if !e.settled]

  # Whether this run may start a NEW execution: whenever the identity is not
  # proven, any job create/replacement (new name, taint, `-replace`) carries
  # run_execution_token, even when the current job already succeeded. Only a
  # proven identity (token suppressed) is exempt. Consequence: while a
  # relevant execution is active, unproven rollout/restore retries are
  # blocked too (re-apply after it finished).
  migration_may_start = var.migration_enabled && !local.proven

  earlier_executions_ok = !local.migration_may_start || (local.exec_valid && length(local.exec_active) == 0)
  earlier_executions_error = (
    !local.exec_parsed ? "the execution inventory (GET jobs/-/executions) is not a parsable 200 list (status ${local.exec_status})" :
    local.exec_truncated ? "the execution inventory has more than one page (nextPageToken); no partial inventory is trusted" :
    "earlier Fleet migration execution(s) still active: ${join(", ", local.exec_active)}"
  )
}
