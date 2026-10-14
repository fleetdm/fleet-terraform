
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

  # Literal so the migration gate can address the service before
  # module.fleet-service is applied (referencing the module would be a cycle).
  fleet_service_name = "fleet-api"

  fleet_vpc_network_id = module.vpc.network_id
  # Use the subnet name from vpc_config variable
  fleet_vpc_subnet_id = var.vpc_config.subnets[0].subnet_name
}

module "fleet-service" {
  source  = "GoogleCloudPlatform/cloud-run/google//modules/v2"
  version = "0.17.2"

  service_name                  = local.fleet_service_name
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
  # The Cloud Run service agent's KMS grant (cmek.cloud_run) and the shared
  # IAM propagation wait (cmek-readiness.tf) must also complete before a
  # CMEK-encrypted revision is deployed; both are empty when CMEK is off.
  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
    google_secret_manager_secret_version.hmac_secret,
    google_secret_manager_secret_version.private_key,
    google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access,
    google_kms_crypto_key_iam_member.cloud_run_cmek,
    time_sleep.cmek_iam_propagation,
    # Service updates (new image, scaling, env) wait for the migration gate:
    # if the gate fails, Terraform does not touch the service, so it can
    # neither restart Fleet nor reset the gate's MANUAL/0 stop to AUTOMATIC
    # (the module does not set scaling_mode, and the provider sends it unset).
    terraform_data.fleet_migration_gate,
  ]
}

# --- Cloud Run Job (Migrations) ---
resource "google_cloud_run_v2_job" "fleet_migration_job" {

  name                = "fleet-migration"
  location            = var.region
  project             = var.project_id
  deletion_protection = false

  template {
    # One task, one attempt: the migration gate verifies a single execution
    # with exactly one task and never retries it.
    task_count  = 1
    parallelism = 1

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

      timeout     = "3600s"
      max_retries = 0

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
  # plus the Cloud Run service agent's KMS grant when cmek.cloud_run is set
  # and the shared IAM propagation wait (cmek-readiness.tf).
  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
    google_secret_manager_secret_version.hmac_secret,
    google_secret_manager_secret_version.private_key,
    google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access,
    google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access,
    google_kms_crypto_key_iam_member.cloud_run_cmek,
    time_sleep.cmek_iam_propagation,
  ]
}

# --- Database migration gate ---
# Runs scripts/fleet_migration_gate.py (Python 3 standard library) on the
# machine running Terraform. With an existing service it stops Fleet (service
# scaling MANUAL with 0 instances, recorded with the pre-migration scaling in
# the fleetdm.com/migration-gate service annotation), waits until Cloud
# Monitoring reports explicit zero active and idle instances for every
# revision, runs the migration job exactly once, verifies it succeeded, deploys
# the new image together with the serving env and CMEK key while still
# stopped, and only then restores the recorded scaling. Every unknown fails
# closed and leaves Fleet stopped for manual recovery; see the README section
# "Database migration gate".
#
# Seam: the controller copies the container env (plain values and secret
# references, e.g. the MySQL/Redis addresses) and the CMEK key from the
# migration job into the service template, because the job and the service are
# built from the same locals (fleet_env_vars, fleet_secrets_env_vars,
# cmek_cloud_run_key_id) and Terraform updates the job first. Keep those
# shared. Job-only settings (command, args, timeout, retries) are never copied;
# other service settings (ports, probes, resources, VPC access) are left as
# they are and applied by module.fleet-service after the gate.
#
# Re-runs (replacement) on the first apply that includes it (initial setup or
# adoption) and whenever one of these changes:
#  * the Fleet image;
#  * the project/region/service/job identity;
#  * the target database: the Cloud SQL instance (sql_instance) or the logical
#    database name (database).
# sql_instance is the instance's connection_name, a computed-only attribute.
# Terraform plans a replacement as a create, and for a create the provider
# leaves that attribute unknown. That holds even when the instance keeps the
# same name (for example, a ForceNew CMEK change). An unknown trigger value
# always replaces this resource, so `fleet prepare db` runs against the new
# instance. Terraform replaces the instance before the gate runs. It does
# not re-run for other job, service or database changes, such as CPU, memory,
# scaling, tier, labels, or extra env. The gate never creates, replaces or
# restores Cloud SQL, and `fleet prepare db` copies no data.
#
# The database and user that the sql-db module creates are not module outputs.
# depends_on = [module.mysql] makes the gate wait for them as well as for the
# instance. This is ordering only; it does not trigger a re-run.
#
# The controller authenticates with Application Default Credentials through
# `gcloud auth application-default print-access-token` at run time; no token
# or secret is passed here or stored in state. Arguments are an argv list (no
# shell) and the environment carries only non-secret identifiers.
resource "terraform_data" "fleet_migration_gate" {
  count = var.fleet_config.exec_migration ? 1 : 0

  triggers_replace = {
    # The image tag is not secret; fleet_config is marked sensitive as a whole.
    image   = nonsensitive(local.fleet_image_tag)
    project = var.project_id
    region  = var.region
    service = local.fleet_service_name
    job     = google_cloud_run_v2_job.fleet_migration_job.name
    # Target database identity (see above). Neither value is secret.
    sql_instance = module.mysql.instance_connection_name
    database     = var.database_config.database_name
  }

  provisioner "local-exec" {
    interpreter = ["python3", "${path.module}/scripts/fleet_migration_gate.py"]
    command     = "run"
    environment = {
      FLEET_GATE_PROJECT        = self.triggers_replace.project
      FLEET_GATE_REGION         = self.triggers_replace.region
      FLEET_GATE_SERVICE        = self.triggers_replace.service
      FLEET_GATE_JOB            = self.triggers_replace.job
      FLEET_GATE_IMAGE          = self.triggers_replace.image
      FLEET_GATE_RUN_ID         = self.id
      FLEET_GATE_TRIGGER        = sha256(jsonencode(self.triggers_replace))
      FLEET_GATE_JOB_GENERATION = google_cloud_run_v2_job.fleet_migration_job.generation
      PYTHONDONTWRITEBYTECODE   = "1"
    }
  }

  depends_on = [google_cloud_run_v2_job.fleet_migration_job, module.mysql]
}

# The previous terracurl_request ran the job with a plan-time OAuth token and
# without stopping Fleet. Forget it without destroying: its destroy action was
# an authenticated GET, which must not run. The terracurl provider stays in
# required_providers so existing state can be read for this removal.
removed {
  from = terracurl_request.exec

  lifecycle {
    destroy = false
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
