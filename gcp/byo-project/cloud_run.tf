
locals {
  # --- Shared Container Configuration ---
  fleet_image_tag = var.fleet_config.image_tag
  fleet_resources_limits = {
    cpu    = var.fleet_config.fleet_cpu
    memory = var.fleet_config.fleet_memory
  }
  # Common Environment Variables - This list of maps can still be used directly
  fleet_common_env_vars = [
    {
      name  = "FLEET_LICENSE_KEY",
      value = var.fleet_config.license_key
    },
    {
      name  = "FLEET_SERVER_FORCE_H2C",
      value = "true"
    },
    {
      name  = "FLEET_MYSQL_PROTOCOL",
      value = "tcp"
    },
    {
      name  = "FLEET_MYSQL_ADDRESS",
      value = "${module.mysql.private_ip_address}:3306"
    },
    {
      name  = "FLEET_MYSQL_USERNAME",
      value = var.database_config.database_user
    },
    {
      name  = "FLEET_MYSQL_DATABASE",
      value = var.database_config.database_name
    },
    {
      name = "FLEET_MYSQL_PASSWORD",
      value_source = {
        secret_key_ref = {
          secret  = google_secret_manager_secret.database_password.secret_id # Corrected to use the versioned secret with random suffix
          version = "latest"
        }
      }
    },
    {
      name = "FLEET_SERVER_PRIVATE_KEY",
      value_source = {
        secret_key_ref = {
          secret  = google_secret_manager_secret.private_key.secret_id # Corrected to use the versioned secret with random suffix
          version = "latest"
        }
      }
    },
    {
      name  = "FLEET_REDIS_ADDRESS",
      value = "${module.memstore.host}:${module.memstore.port}"
    },
    {
      name  = "FLEET_LOGGING_JSON",
      value = "true"
    },
    {
      name  = "FLEET_LOGGING_DEBUG",
      value = var.fleet_config.debug_logging
    },
    {
      name  = "FLEET_SERVER_TLS",
      value = "false"
    },
    # S3 Variables
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_BUCKET",
      value = google_storage_bucket.software_installers.id
    },
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_ACCESS_KEY_ID",
      value = google_storage_hmac_key.key.access_id
    },
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY",
      value = google_storage_hmac_key.key.secret
    },
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_ENDPOINT_URL",
      value = "https://storage.googleapis.com"
    },
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_FORCE_S3_PATH_STYLE",
      value = "true"
    },
    {
      name  = "FLEET_S3_SOFTWARE_INSTALLERS_REGION",
      value = data.google_client_config.current.region
    },
  ]

  # --- Shared VPC Access Configuration Parts ---
  # These will be used to construct the block
  fleet_vpc_network_id = module.vpc.network_id
  # Use the direct construction for the subnet ID key as discussed
  fleet_vpc_subnet_id = "fleet-subnet"
}

# --- Cloud Run Service (Main Webserver) ---
resource "google_cloud_run_v2_service" "fleet_service" {
  name                = "${var.prefix}-service"
  location            = var.region
  project             = var.project_id
  deletion_protection = false

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  timeouts {
    create = "300s"
    update = "300s"
  }

  template {
    service_account = google_service_account.fleet_run_sa.email # Defined in iam.tf

    # Define vpc_access block directly
    vpc_access {
      network_interfaces {
        network    = local.fleet_vpc_network_id
        subnetwork = local.fleet_vpc_subnet_id
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      image = local.fleet_image_tag
      ports {
        name           = "h2c"
        container_port = 8080
      }
      command = ["/bin/sh"]
      args = [
        "-c",
        "fleet prepare --no-prompt=true db; exec fleet serve"
      ]

      startup_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 5
        period_seconds        = 3
        failure_threshold     = 3
        tcp_socket {
          port = 8080
        }
      }
      liveness_probe {
        http_get {
          path = "/healthz"
        }
      }

      resources {
        limits = local.fleet_resources_limits
      }

      dynamic "env" {
        for_each = local.fleet_common_env_vars
        content {
          name  = env.value.name
          value = try(env.value.value, null)
          dynamic "value_source" {
            for_each = try(env.value.value_source, null) != null ? [env.value.value_source] : []
            content {
              secret_key_ref {
                secret  = value_source.value.secret_key_ref.secret
                version = value_source.value.secret_key_ref.version
              }
            }
          }
        }
      }
    }

    scaling {
      min_instance_count = var.fleet_config.min_instance_count
      max_instance_count = var.fleet_config.max_instance_count
    }
  }

  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
    google_secret_manager_secret_version.private_key,
  ]
}

# --- Cloud Run Job (Migrations) ---
resource "google_cloud_run_v2_job" "fleet_migration_job" {

  name     = "${var.prefix}-migration-job"
  location = var.region
  project  = var.project_id

  template {
    template {                                                    # Double template for jobs
      service_account = google_service_account.fleet_run_sa.email # Defined in iam.tf

      # Define vpc_access block directly
      vpc_access {
        network_interfaces {
          network    = local.fleet_vpc_network_id
          subnetwork = local.fleet_vpc_subnet_id
        }
        egress = "ALL_TRAFFIC"
      }

      timeout = "3600s"

      containers {
        image = local.fleet_image_tag
        # Define resources block directly
        resources {
          limits = local.fleet_resources_limits
        }
        # Define env block directly, iterating over the local list
        dynamic "env" {
          for_each = local.fleet_common_env_vars
          content {
            name  = env.value.name
            value = try(env.value.value, null)
            dynamic "value_source" {
              for_each = try(env.value.value_source, null) != null ? [env.value.value_source] : []
              content {
                secret_key_ref {
                  secret  = value_source.value.secret_key_ref.secret
                  version = value_source.value.secret_key_ref.version
                }
              }
            }
          }
        }

        command = ["fleet"]
        args    = ["prepare", "db", "--no-prompt=true"]
      }
    }
  }

  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
  ]
}

resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "${var.prefix}-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS" # This type works for Cloud Run v2 services
  cloud_run {
    service = google_cloud_run_v2_service.fleet_service.name # Reference the v2 service name
  }
  depends_on = [google_cloud_run_v2_service.fleet_service]
}
