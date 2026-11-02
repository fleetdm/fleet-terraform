# -----------------------------------------------------------------------------
# The single owner of the Fleet Cloud Run service (replaces
# module.fleet-service.google_cloud_run_v2_service.main of cloud-run v0.17.2;
# moved in byo-project/cloud_run.tf). Same template as the module rendered
# for Fleet, plus:
#   * scaling_mode declared explicitly: MANUAL/0 until the current migration
#     identity is proven restored (marker), AUTOMATIC/min afterwards. The
#     module could not express scaling_mode.
#   * a revision-template attempt annotation (Job UID) so every migration
#     attempt deploys a fresh revision while still MANUAL/0 and the provider
#     waits for it to become Ready ("staged" restore).
#   * the restore marker annotation is NOT declared (left to the restore
#     PATCH; preserved by the provider's effective_annotations handling).
# -----------------------------------------------------------------------------
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

    annotations = var.migration_enabled ? { (var.attempt_annotation_key) = local.attempt_value } : {}

    scaling {
      min_instance_count = 0 # Google suggests the service-level minimum
      max_instance_count = var.max_instance_count
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

  # Ordering: secrets/IAM/CMEK via prerequisites; the migration job through
  # the attempt annotation (job UID) reference above.
  depends_on = [terraform_data.prerequisites, google_cloud_run_v2_job.migration]
}
