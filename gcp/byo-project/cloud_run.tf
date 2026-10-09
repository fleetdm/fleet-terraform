
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
      secret  = local.fleet_private_key_secret_name
      version = "latest"
    },
    FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY = {
      secret  = google_secret_manager_secret.hmac_secret.secret_id
      version = "latest"
    }
  })
  fleet_env_vars = merge(var.fleet_config.extra_env_vars, {
    FLEET_LICENSE_KEY      = var.fleet_config.license_key
    FLEET_SERVER_FORCE_H2C = var.fleet_config.use_h2c
    FLEET_MYSQL_PROTOCOL   = "tcp"
    FLEET_MYSQL_ADDRESS    = "${module.mysql.private_ip_address}:3306"
    FLEET_MYSQL_USERNAME   = var.database_config.database_user
    FLEET_MYSQL_DATABASE   = var.database_config.database_name
    FLEET_REDIS_ADDRESS    = "${module.memstore.host}:${module.memstore.port}"
    FLEET_REDIS_USE_TLS    = "false"
    # FLEET_UPGRADES_ALLOW_MISSING_MIGRATIONS          = "1"
    FLEET_LOGGING_JSON                               = "true"
    FLEET_LOGGING_DEBUG                              = var.fleet_config.debug_logging
    FLEET_SERVER_TLS                                 = "false"
    FLEET_S3_SOFTWARE_INSTALLERS_BUCKET              = google_storage_bucket.software_installers.id
    FLEET_S3_SOFTWARE_INSTALLERS_ACCESS_KEY_ID       = google_storage_hmac_key.key.access_id
    FLEET_S3_SOFTWARE_INSTALLERS_ENDPOINT_URL        = "https://storage.googleapis.com"
    FLEET_S3_SOFTWARE_INSTALLERS_FORCE_S3_PATH_STYLE = "true"
    FLEET_S3_SOFTWARE_INSTALLERS_REGION              = var.region
  })

  fleet_vpc_network_id = module.vpc.network_id
  # Use the subnet name from vpc_config variable
  fleet_vpc_subnet_id = var.vpc_config.subnets[0].subnet_name
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

  # Opt-in CMEK (cmek.cloud_run). null = Google-managed (unchanged default).
  # Changing it rolls out a new revision; the service is not replaced.
  encryption_key = local.cmek_cloud_run_key_id

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
    min_instance_count = var.fleet_config.min_instance_count
  }

  template_scaling = {
    min_instance_count = 0 # Google suggests using service-level minimum instance count
    max_instance_count = var.fleet_config.max_instance_count
  }

  containers = [
    {
      container_image = local.fleet_image_tag
      ports = {
        name           = var.fleet_config.use_h2c ? "h2c" : "http1"
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

  # Cloud Run resolves secret env vars ("latest") when a revision starts, so
  # every managed secret version and every secretAccessor grant for the run
  # service account must exist before the service is created or updated.
  # google_secret_manager_secret_version.private_key is referenced as a whole
  # collection: it has count = 0 when an external private-key secret is used,
  # in which case the dependency is a no-op and only the IAM grant on the
  # external secret applies.
  # The Cloud Run service agent's KMS grant (cmek.cloud_run) must also exist
  # before a CMEK-encrypted revision is deployed; empty when CMEK is off.
  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
    google_secret_manager_secret_version.hmac_secret,
    google_secret_manager_secret_version.private_key,
    google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access,
    google_kms_crypto_key_iam_member.cloud_run_cmek,
  ]
}

# --- Cloud Run Job (Migrations) ---
resource "google_cloud_run_v2_job" "fleet_migration_job" {

  name                = "fleet-migration"
  location            = var.region
  project             = var.project_id
  deletion_protection = false

  template {
    template {                                                    # Double template for jobs
      service_account = google_service_account.fleet_run_sa.email # Defined in iam.tf

      # Same opt-in CMEK key as the service (null = Google-managed).
      encryption_key = local.cmek_cloud_run_key_id

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

  # Same secret readiness gate as module.fleet-service (see the comment
  # there): all secret versions and secretAccessor grants must exist first,
  # plus the Cloud Run service agent's KMS grant when cmek.cloud_run is set.
  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
    google_secret_manager_secret_version.hmac_secret,
    google_secret_manager_secret_version.private_key,
    google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access,
    google_kms_crypto_key_iam_member.cloud_run_cmek,
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
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = module.fleet-service.service_name
  }
  depends_on = [module.fleet-service]
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_invoker" {
  project  = var.project_id
  location = module.fleet-service.location
  name     = module.fleet-service.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
