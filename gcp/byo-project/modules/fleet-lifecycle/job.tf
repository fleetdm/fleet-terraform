# -----------------------------------------------------------------------------
# Migration job: one Cloud Run job per migration attempt.
#
# The job is an IMMUTABLE EXECUTION ARTIFACT: it is created (with the CURRENT
# configuration) only when its name changes (new identity, or a live failed
# job/execution of the same identity) or when it is tainted. In-place changes
# to an existing job are ignored, so ordinary env/label/CMEK churn never re-sends
# run_execution_token and never launches a migration. The next migration job
# picks up the current settings.
#
# CREATE with run_execution_token: Cloud Run starts one execution named
# <job>-<token> and the create LRO is documented to complete when that
# execution completes ("the Job will become ready when the execution is
# successfully completed"). The google-beta provider stores the ID before
# waiting, so:
#   * LRO done.error   -> provider error -> resource TAINTED -> next apply
#                         re-creates it (one fresh execution).
#   * LRO done.response -> provider reports success. The Job's own
#                         terminal_condition is the Job's readiness, not the
#                         execution's outcome, so it is not trusted:
#                         data.terracurl_request.job_execution (below) reads
#                         latestCreatedExecution.completionStatus and the
#                         service (deploy) and restore only proceed on exactly
#                         EXECUTION_SUCCEEDED. Missing, pending, running,
#                         failed or cancelled: the apply fails, Fleet stays
#                         MANUAL/0. The next plan sees a failed/cancelled
#                         execution via jobs_live and plans a new job name.
# The google-beta provider (6.x, and 7.x as of 7.24) does not expose
# completionStatus, hence the metadata-only GET.
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "migration" {
  provider = google-beta
  count    = local.migration_count

  name                = local.job_name
  location            = var.region
  project             = var.project_id
  deletion_protection = false

  labels = {
    (local.identity_label) = local.identity_hex
  }

  # Unique per create (timestamp is only known during apply). Suppressed when
  # the identity is already migrated (main.tf): a job that is merely re-created
  # (e.g. deleted out of band) must not run a migration while Fleet is AUTO.
  run_execution_token = local.migrated ? null : "r${formatdate("YYMMDDhhmmss", timestamp())}"

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = var.service_account_email
      encryption_key  = var.encryption_key
      timeout         = var.migration_task_timeout
      max_retries     = 0

      vpc_access {
        network_interfaces {
          network    = var.vpc_network
          subnetwork = var.vpc_subnetwork
        }
        egress = "ALL_TRAFFIC"
      }

      containers {
        image   = var.image
        command = var.migration_command
        args    = var.migration_args

        resources {
          limits = {
            cpu    = var.cpu
            memory = var.memory
          }
        }

        dynamic "env" {
          for_each = var.env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = env.value.version
              }
            }
          }
        }
      }
    }
  }

  timeouts {
    create = var.job_create_timeout
  }

  lifecycle {
    ignore_changes = [
      template, labels, annotations, client, client_version, launch_stage,
      binary_authorization, run_execution_token, start_execution_token,
    ]

    precondition {
      condition     = !local.jobs_truncated && length(local.identity_jobs) <= 1
      error_message = "Cannot classify migration jobs for this identity (job list truncated, or more than one job carries label ${local.identity_label}=${local.identity_hex}). This happens after a hard-killed apply left an orphan job outside state. Inspect it, then import or delete it; no migration was started."
    }

    # Read at plan from jobs_live: a tainted (or -replace'd) job of this
    # identity is never deleted while its execution is still pending/running.
    precondition {
      condition     = local.migrated || !contains(["EXECUTION_PENDING", "EXECUTION_RUNNING"], local.current_exec)
      error_message = "The migration job of this identity still has a pending or running execution; it is not replaced or deleted while it runs. Wait until it has finished, then run `terraform apply` again."
    }

    # The check above is unknown (deferred past the delete) while the identity
    # is replaced, e.g. on an image or database change. This one is not.
    precondition {
      condition     = length(local.running_jobs) == 0
      error_message = "A migration job's execution is still pending or running: ${join(", ", local.running_jobs)}. No job is replaced or deleted and no migration starts while it runs. Wait until it has finished, then run `terraform apply` again."
    }
  }

  depends_on = [time_sleep.drain, terraform_data.prerequisites]
}

# Deferred token: read after the job step (the execution may run for up to an
# hour, longer than a plan-time token lives).
data "google_client_config" "job" {
  provider   = google-beta
  depends_on = [google_cloud_run_v2_job.migration]
}

# Execution outcome of this attempt's job (metadata only). Re-read every plan;
# deferred to apply while the job changes. The gate is a precondition on the
# service (service.tf), so a failed execution neither deploys nor restores.
data "terracurl_request" "job_execution" {
  count = local.migration_count

  name           = "fleet-lifecycle-job-execution"
  url            = "${local.run_api}/${local.parent}/jobs/${google_cloud_run_v2_job.migration[0].name}?fields=${urlencode(local.job_fields)}"
  method         = "GET"
  headers        = { Authorization = "Bearer ${data.google_client_config.job.access_token}" }
  response_codes = ["200"]
  timeout        = 30
  max_retry      = 2
  retry_interval = 10

  depends_on = [google_cloud_run_v2_job.migration]
}

locals {
  job_view = var.migration_enabled ? try(jsondecode(data.terracurl_request.job_execution[0].response), null) : null
  # Exactly EXECUTION_SUCCEEDED (and a succeeded Job); anything else fails closed.
  migration_succeeded = try(
    local.job_view.terminalCondition.state == "CONDITION_SUCCEEDED" &&
    local.job_view.latestCreatedExecution.completionStatus == "EXECUTION_SUCCEEDED",
    false,
  )
}
