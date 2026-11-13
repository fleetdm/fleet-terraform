# -----------------------------------------------------------------------------
# The single owner of the Fleet Cloud Run service (replaces
# main's module.fleet-service.google_cloud_run_v2_service.main;
# moved in byo-project/cloud_run.tf). Same template as main rendered
# for Fleet, plus:
#   * scaling_mode declared explicitly: MANUAL/0 until the current migration
#     identity is migrated (`migrated` in main.tf), AUTOMATIC/min afterwards.
#     The module could not express scaling_mode.
#   * a revision-template attempt annotation (Job UID) so every migration
#     attempt deploys a fresh revision while still MANUAL/0 and the provider
#     waits for it to become Ready ("staged" restore).
#   * the restore marker annotation is NOT declared (left to the restore
#     PATCH; preserved by the provider's effective_annotations handling).
#   * a disk-backed /tmp (var.tmp_volume_config, on by default): one Cloud Run
#     ephemeral disk volume (empty_dir, medium DISK) mounted at /tmp in the
#     Fleet container. The migration job gets no volume, and the setting is
#     not part of the migration identity: adding, resizing or removing it is
#     an ordinary in-place template update (new revision, no migration).
# -----------------------------------------------------------------------------

locals {
  # The volume's medium is the literal "DISK" below, never MEMORY (MEMORY is
  # the in-memory /tmp this replaces). Ephemeral disk needs the GEN2
  # execution environment declared on the template.
  tmp_volume_enabled = var.tmp_volume_config.enable
  tmp_volume_name    = "tmp"
  tmp_mount_path     = "/tmp"
  tmp_volume_size    = "${var.tmp_volume_config.size_gib}Gi"
}

resource "google_cloud_run_v2_service" "fleet" {
  provider = google-beta

  project             = var.project_id
  name                = var.service_name
  location            = var.region
  deletion_protection = false
  ingress             = var.ingress
  launch_stage        = "GA"

  # The restore marker is deliberately NOT declared: the provider sends
  # effective_annotations (refreshed server map + config), so an unmanaged key
  # survives provider updates, and declaring it would add a one-time diff
  # after every restore (observed with the real provider in the loopback
  # integration run).
  annotations = var.service_annotations

  scaling {
    scaling_mode          = local.serving ? "AUTOMATIC" : "MANUAL"
    manual_instance_count = local.serving ? null : 0
    min_instance_count    = local.serving ? var.min_instance_count : 0
  }

  # Declared exactly LATEST/100 without tags (as the module did implicitly).
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  template {
    timeout               = var.request_timeout
    service_account       = var.service_account_email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    encryption_key        = var.encryption_key

    annotations = var.migration_enabled ? { (local.attempt_annotation_key) = local.attempt_value } : {}

    scaling {
      min_instance_count = 0 # Google suggests the service-level minimum
      max_instance_count = var.max_instance_count
    }

    # Disk-backed /tmp (see the header). enable = false declares neither this
    # volume nor the mount below, i.e. the previous in-memory /tmp.
    dynamic "volumes" {
      for_each = local.tmp_volume_enabled ? [local.tmp_volume_name] : []
      content {
        name = volumes.value
        empty_dir {
          medium     = "DISK"
          size_limit = local.tmp_volume_size
        }
      }
    }

    vpc_access {
      network_interfaces {
        network    = var.vpc_network
        subnetwork = var.vpc_subnetwork
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      image = var.image

      ports {
        name           = var.use_h2c ? "h2c" : "http1"
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      dynamic "volume_mounts" {
        for_each = local.tmp_volume_enabled ? [local.tmp_volume_name] : []
        content {
          name       = volume_mounts.value
          mount_path = local.tmp_mount_path
        }
      }

      startup_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3
        tcp_socket {
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3
        http_get {
          path = "/healthz"
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

  lifecycle {
    # Migration-success gate (job.tf): no deploy, and therefore no restore,
    # unless this attempt's execution reports exactly EXECUTION_SUCCEEDED.
    precondition {
      condition     = !var.migration_enabled || local.migrated || local.migration_succeeded
      error_message = "Refusing to deploy or restore Fleet: the migration execution of this attempt has not succeeded (job terminal condition and latestCreatedExecution.completionStatus must be CONDITION_SUCCEEDED / EXECUTION_SUCCEEDED). Fleet stays stopped (MANUAL/0). Job status: ${jsonencode(local.job_view)}. A failed or cancelled execution is retried with a new job by the next `terraform apply`; a pending or running one: wait until it has finished, then apply again."
    }
  }

  # Ordering: secrets/IAM/CMEK via prerequisites; the migration job and its
  # execution read-back (job.tf).
  depends_on = [terraform_data.prerequisites, data.terracurl_request.job_execution]
}
