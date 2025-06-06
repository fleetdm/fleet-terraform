
locals {
  # --- Shared Container Configuration ---
  fleet_image_tag = var.fleet_config.image_tag
  fleet_resources_limits = {
    cpu    = var.fleet_config.fleet_cpu
    memory = var.fleet_config.fleet_memory
  }
  fleet_secrets_env_vars = merge(var.fleet_config.extra_secret_env_vars, {
    FLEET_MYSQL_PASSWORD = {
      secret  = google_secret_manager_secret.database_password.secret_id
      version = "latest"
    },
    FLEET_SERVER_PRIVATE_KEY = {
      secret  = google_secret_manager_secret.private_key.secret_id
      version = "latest"
    }
  })
  fleet_env_vars = merge(var.fleet_config.extra_env_vars, {
    FLEET_LICENSE_KEY      = var.fleet_config.license_key
    FLEET_SERVER_FORCE_H2C = "true"
    FLEET_MYSQL_PROTOCOL   = "tcp"
    FLEET_MYSQL_ADDRESS    = "${module.mysql.private_ip_address}:3306"
    FLEET_MYSQL_USERNAME   = var.database_config.database_user
    FLEET_MYSQL_DATABASE   = var.database_config.database_name
    FLEET_REDIS_ADDRESS    = "${module.memstore.host}:${module.memstore.port}"
    FLEET_REDIS_USE_TLS    = "false"
    #FLEET_UPGRADES_ALLOW_MISSING_MIGRATIONS          = "1"
    FLEET_LOGGING_JSON                               = "true"
    FLEET_LOGGING_DEBUG                              = var.fleet_config.debug_logging
    FLEET_SERVER_TLS                                 = "false"
    FLEET_S3_SOFTWARE_INSTALLERS_BUCKET              = google_storage_bucket.software_installers.id
    FLEET_S3_SOFTWARE_INSTALLERS_ACCESS_KEY_ID       = google_storage_hmac_key.key.access_id
    FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY   = google_storage_hmac_key.key.secret
    FLEET_S3_SOFTWARE_INSTALLERS_ENDPOINT_URL        = "https://storage.googleapis.com"
    FLEET_S3_SOFTWARE_INSTALLERS_FORCE_S3_PATH_STYLE = "true"
    FLEET_S3_SOFTWARE_INSTALLERS_REGION              = var.region
  })

  fleet_vpc_network_id = module.vpc.network_id
  # Use the direct construction for the subnet ID key as discussed
  fleet_vpc_subnet_id = "fleet-subnet"
}

module "fleet-service" {
  source  = "GoogleCloudPlatform/cloud-run/google//modules/v2"
  version = "0.17.2"

  service_name                  = "fleet-api"
  project_id                    = var.project_id
  location                      = var.region
  create_service_account        = false
  service_account               = google_service_account.fleet_run_sa.email
  enable_prometheus_sidecar     = false
  cloud_run_deletion_protection = false

  vpc_access = {
    network_interfaces = {
      network    = local.fleet_vpc_network_id
      subnetwork = local.fleet_vpc_subnet_id
    }
    egress = "ALL_TRAFFIC"
  }
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  timeout = "300s"
  service_scaling = {
    min_instance_count = 0
  }
  template_scaling = {
    min_instance_count = 0
    max_instance_count = 0
  }

  containers = [
    {
      container_image = local.fleet_image_tag
      ports = {
        name           = "h2c"
        container_port = 8080
      }
      # container_command = ["/bin/sh"]
      # container_args = [
      #   "-c",
      #   "fleet prepare --no-prompt=true db; exec fleet serve"
      # ]

      startup_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3

        tcp_socket = {
          port = 8080
        }
      }

      liveness_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        failure_threshold     = 3
        period_seconds        = 60
        http_get = {
          path         = "/healthz"
          http_headers = []
        }
      }

      resources = {
        limits = local.fleet_resources_limits
      }

      env_vars        = local.fleet_env_vars
      env_secret_vars = local.fleet_secrets_env_vars
    }
  ]
}

# --- Cloud Run Job (Migrations) ---
resource "google_cloud_run_v2_job" "fleet_migration_job" {

  name     = "fleet-migration"
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

        dynamic "env" {
          for_each = local.fleet_env_vars
          content {
            name  = env.key
            value = env.value
          }
        }
        dynamic "env" {
          for_each = local.fleet_secrets_env_vars
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

data "google_client_config" "default" {}

resource "terracurl_request" "exec" {
  count  = var.fleet_config.exec_migration ? 1 : 0
  name   = "exec-job"
  url    = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.fleet_migration_job.id}:run"
  method = "POST"
  headers = {
    Authorization = "Bearer ${data.google_client_config.default.access_token}"
    Content-Type  = "application/json",
  }
  response_codes = [200]
  // no-op destroy
  // we don't use terracurl_request data source as that will result in
  // repeated job runs on every refresh
  destroy_url            = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.fleet_migration_job.id}"
  destroy_method         = "GET"
  destroy_response_codes = [200]
  destroy_headers = {
    Authorization = "Bearer ${data.google_client_config.default.access_token}"
    Content-Type  = "application/json",
  }
}

resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "${var.prefix}-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS" # This type works for Cloud Run v2 services
  cloud_run {
    service = module.fleet-service.service_name
  }
  depends_on = [module.fleet-service]
}

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_invoker" {
  project  = var.project_id
  location = module.fleet-service.location
  name     = module.fleet-service.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}