
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

  # Literal: the lifecycle module's stop/restore REST calls address the
  # service by name before the service resource is applied.
  fleet_service_name = "fleet-api"

  fleet_vpc_network_id = module.vpc.network_id
  # Use the subnet name from vpc_config variable
  fleet_vpc_subnet_id = var.vpc_config.subnets[0].subnet_name
}

# The database and user created by the sql-db module are not module outputs.
# This ordering-only node waits for the whole module (instance, database,
# user) and is fed into the lifecycle prerequisites, so the migration job and
# the service never run before them. It never triggers a migration.
resource "terraform_data" "fleet_database_ready" {
  depends_on = [module.mysql]
}

# --- Fleet service + provider-only migration lifecycle ---
# Replaces module.fleet-service (cloud-run v0.17.2, which cannot express
# scaling_mode), the fixed-name google_cloud_run_v2_job.fleet_migration_job
# and the terracurl_request.exec trigger. See modules/fleet-lifecycle.
# Apply path: providers only.
module "fleet_lifecycle" {
  source = "./modules/fleet-lifecycle"

  project_id   = var.project_id
  region       = var.region
  service_name = local.fleet_service_name

  # The image tag is not secret; fleet_config is marked sensitive as a whole.
  image                 = nonsensitive(local.fleet_image_tag)
  service_account_email = google_service_account.fleet_run_sa.email
  encryption_key        = local.cmek_cloud_run_key_id
  vpc_network           = local.fleet_vpc_network_id
  vpc_subnetwork        = local.fleet_vpc_subnet_id
  ingress               = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  request_timeout       = "300s"
  use_h2c               = nonsensitive(var.fleet_config.use_h2c)
  cpu                   = local.fleet_resources_limits.cpu
  memory                = local.fleet_resources_limits.memory
  env                   = local.fleet_env_vars
  secret_env            = local.fleet_secrets_env_vars
  min_instance_count    = var.fleet_config.min_instance_count
  max_instance_count    = var.fleet_config.max_instance_count

  migration_enabled = nonsensitive(var.fleet_config.exec_migration)
  # connection_name is computed-only: planned unknown on (same-name)
  # replacement => new migration identity.
  database_identity = {
    sql_connection_name = module.mysql.instance_connection_name
    database_name       = var.database_config.database_name
  }

  # Ordering only (same readiness set as the former module-wide depends_on).
  prerequisites = concat(
    [
      google_service_account.fleet_run_sa.id,
      google_secret_manager_secret_version.database_password.id,
      google_secret_manager_secret_version.hmac_secret.id,
      google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access.etag,
      google_secret_manager_secret_iam_member.fleet_run_sa_hmac_secret_access.etag,
      google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access.etag,
      terraform_data.fleet_database_ready.id,
    ],
    google_secret_manager_secret_version.private_key[*].id,
    google_kms_crypto_key_iam_member.cloud_run_cmek[*].etag,
    time_sleep.cmek_iam_propagation[*].id,
  )
}

# Single service owner: adopt the module's service in place (no destroy /
# recreate). Same resource type and provider (google-beta).
moved {
  from = module.fleet-service.google_cloud_run_v2_service.main
  to   = module.fleet_lifecycle.google_cloud_run_v2_service.fleet
}

# The fixed-name `fleet-migration` job of earlier releases is forgotten, not
# destroyed: deleting a job whose execution might still be running is not
# something an apply should do implicitly. Delete `fleet-migration` by hand
# after review.
removed {
  from = google_cloud_run_v2_job.fleet_migration_job

  lifecycle {
    destroy = false
  }
}

# The earlier terracurl_request.exec ran that job with a plan-time OAuth token
# and without stopping Fleet. Forget it without destroying: its destroy action
# was an authenticated GET, which must not run.
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
    service = module.fleet_lifecycle.service_name
  }
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_invoker" {
  project  = var.project_id
  location = module.fleet_lifecycle.service_location
  name     = module.fleet_lifecycle.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
