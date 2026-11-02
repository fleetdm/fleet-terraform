# -----------------------------------------------------------------------------
# Migration job: one Cloud Run job per migration attempt.
#
# The job is an IMMUTABLE EXECUTION ARTIFACT: it is created (with the CURRENT
# configuration) only when its name changes (new identity, or a live FAILED
# job of the same identity) or when it is tainted. In-place changes to an
# existing job are ignored, so ordinary env/label/CMEK churn never re-sends
# run_execution_token and never launches a migration. The next migration job
# picks up the current settings.
#
# CREATE with run_execution_token: Cloud Run starts one execution named
# <job>-<token> and the create LRO is documented to complete when that
# execution completes ("the Job will become ready when the execution is
# successfully completed"). The google-beta provider stores the ID before
# waiting, so:
#   * LRO done.error          -> provider error -> resource TAINTED -> next
#                                apply re-creates it (one fresh execution).
#   * LRO done.response with  -> provider reports success; the postcondition
#     terminalCondition FAILED   below fails the apply (no restore, Fleet stays
#                                MANUAL/0). A postcondition does NOT taint; the
#                                next plan sees the live FAILED job via
#                                data.terracurl_request.jobs_live and plans a
#                                new job name instead.
# Which shape Google emits for a failed `fleet prepare db` is NOT verified.
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
  # the identity is already proven restored: a job that is merely re-created
  # (e.g. deleted out of band) must not run a migration while Fleet is AUTO.
  run_execution_token = local.proven ? null : "r${formatdate("YYMMDDhhmmss", timestamp())}"

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
      error_message = "Cannot classify migration jobs for this identity (job list truncated, or more than one job carries label ${local.identity_label}=${local.identity_hex}). This happens after a hard-killed apply left an orphan job outside state. Import or delete the orphan; no migration was started."
    }

    # Earlier-migration guard (executions.tf). When the inventory is readable
    # at plan (e.g. a tainted job that keeps its name) this fails the PLAN, so
    # a tainted job whose execution is still running is never deleted.
    precondition {
      condition     = local.earlier_executions_ok
      error_message = "Refusing to start a new Fleet migration: ${local.earlier_executions_error}. No new migration job was created and earlier jobs are left untouched. Wait until the earlier execution has finished (or cancel it yourself), then run `terraform apply` again."
    }

    postcondition {
      # No list indexing: an empty terminal_condition (failed create) must not
      # turn into "Invalid index" noise.
      condition     = local.proven || contains([for c in self.terminal_condition : c.state], "CONDITION_SUCCEEDED")
      error_message = "Migration job ${self.name} did not succeed (terminal condition: ${jsonencode([for c in self.terminal_condition : { state = c.state, reason = c.reason, message = c.message }])}). Fleet stays stopped (MANUAL/0). Fix the cause and run `terraform apply` again: a FAILED job is replaced by a new one automatically; a job still running blocks until it settles."
    }
  }

  depends_on = [time_sleep.drain, terraform_data.prerequisites]
}
