// Plan-only wiring checks for the provider-only lifecycle module
// (modules/fleet-lifecycle) inside the full byo-project stack. Every
// provider is mocked; nothing contacts Google Cloud. The apply path has no
// provisioner, so these could also run as mocked applies; the lifecycle
// behaviour itself is covered by modules/fleet-lifecycle/tests and the
// loopback-fake integration harness (lifecycle-tests/integration).
//
// The identity's sql_connection_name is the instance's computed
// connection_name. Re-running on a (same-name) replacement relies on the real
// provider planning that attribute as unknown; mocks cannot show that, so the
// connection name below is test input (override_during = plan).

mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b", "us-central1-c"]
    }
  }
}
mock_provider "google-beta" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "terracurl" {
  # Status reads default to "service absent" (fresh deployment).
  mock_data "terracurl_request" {
    defaults = { status_code = "404", response = "{}" }
  }
}
mock_provider "time" {}

variables {
  project_id      = "fleet-test-project"
  dns_zone_name   = "example.com."
  dns_record_name = "fleet.example.com."
  fleet_config = {
    image_tag              = "fleetdm/fleet:v4.93.0"
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    use_h2c                = false
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
    installers_bucket_name = "fleet-test-installers"
  }
}

run "lifecycle_enabled_by_default" {
  command = plan
  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  assert {
    condition = module.fleet_lifecycle.migration_identity_triggers == {
      image               = "fleetdm/fleet:v4.93.0"
      project             = "fleet-test-project"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet"
    }
    error_message = "Migration identity contract: image, project, region, service, SQL connection_name, database."
  }

  assert {
    condition     = module.fleet_lifecycle.service_name == "fleet-api" && output.cloud_run_service_name == "fleet-api"
    error_message = "The stop/restore requests address the literal service name fleet-api."
  }

  assert {
    condition     = google_compute_region_network_endpoint_group.neg.cloud_run[0].service == "fleet-api"
    error_message = "The serverless NEG must point at the lifecycle-owned service."
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.allow_lb_invoker.name == "fleet-api"
    error_message = "The LB invoker grant must target the lifecycle-owned service."
  }
}

// The NEGs must not reference the lifecycle module's resource-backed service
// name: the load balancer's create_before_destroy would propagate through them
// to the service and the migration job (same-name job re-create => 409). Both
// expressions resolve to "fleet-api", so a sentinel module output tells them
// apart. The invoker grant keeps the resource-backed name (service first).
run "negs_do_not_depend_on_lifecycle_service" {
  command = plan

  variables {
    load_balancer_config = { use_regional_lb = true }
  }

  override_module {
    target  = module.fleet_lifecycle
    outputs = { service_name = "lifecycle-output-sentinel", service_location = "us-central1" }
  }

  assert {
    condition = (
      google_compute_region_network_endpoint_group.neg.cloud_run[0].service == "fleet-api" &&
      google_compute_region_network_endpoint_group.regional_neg[0].cloud_run[0].service == "fleet-api"
    )
    error_message = "The global and regional serverless NEGs must use local.fleet_service_name, not module.fleet_lifecycle.service_name."
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.allow_lb_invoker.name == "lifecycle-output-sentinel"
    error_message = "The LB invoker grant must keep module.fleet_lifecycle.service_name (created after the service)."
  }
}

run "job_is_single_task_single_attempt_with_serving_env" {
  command = plan

  assert {
    condition = (
      nonsensitive(module.fleet_lifecycle.migration_job.template[0].task_count) == 1 &&
      nonsensitive(module.fleet_lifecycle.migration_job.template[0].parallelism) == 1 &&
      nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].max_retries) == 0 &&
      nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].timeout) == "3600s"
    )
    error_message = "The migration job must be one task, parallelism 1, max_retries 0, 3600s."
  }

  assert {
    condition     = nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].containers[0].args) == tolist(["prepare", "db", "--no-prompt=true"])
    error_message = "The migration job must run `fleet prepare db`."
  }

  assert {
    condition = alltrue([
      for n in ["FLEET_MYSQL_ADDRESS", "FLEET_MYSQL_DATABASE", "FLEET_REDIS_ADDRESS", "FLEET_MYSQL_PASSWORD", "FLEET_SERVER_PRIVATE_KEY"] :
      contains([for e in nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].containers[0].env) : e.name], n)
    ])
    error_message = "The migration job must carry the Fleet env (MySQL/Redis endpoints and secret references)."
  }
}

run "service_template_preserved" {
  command = plan

  assert {
    condition = (
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].image) == "fleetdm/fleet:v4.93.0" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].resources[0].limits) == tomap({ cpu = "1000m", memory = "4096Mi" }) &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].ports[0].name) == "http1" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].ports[0].container_port) == 8080 &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].startup_probe[0].tcp_socket[0].port) == 8080 &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].liveness_probe[0].http_get[0].path) == "/healthz" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].timeout) == "300s" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].vpc_access[0].egress) == "ALL_TRAFFIC" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].encryption_key) == null &&
      nonsensitive(module.fleet_lifecycle.service.template[0].scaling[0].max_instance_count) == 5 &&
      nonsensitive(module.fleet_lifecycle.service.ingress) == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
    )
    error_message = "The direct service resource must keep the module-rendered Fleet template (image, 4096Mi, port, probes, timeout, VPC, CMEK, ingress)."
  }

  assert {
    condition = alltrue([
      for n in ["FLEET_MYSQL_PASSWORD", "FLEET_SERVER_PRIVATE_KEY", "FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY"] :
      contains([for e in nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].env) : e.name if length(e.value_source) == 1], n)
    ])
    error_message = "Secret env must stay Secret Manager references."
  }

  assert {
    condition     = module.fleet_lifecycle.declared_scaling_mode == "MANUAL" && nonsensitive(module.fleet_lifecycle.service.scaling[0].scaling_mode) == "MANUAL"
    error_message = "Without a restore marker on the live service (mock: absent), the service is declared MANUAL/0 until the first migration is restored (always-migrate first adoption)."
  }
}

run "image_change_changes_identity" {
  command = plan
  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  variables {
    fleet_config = {
      image_tag              = "fleetdm/fleet:v4.94.0"
      fleet_cpu              = "1000m"
      fleet_memory           = "4096Mi"
      debug_logging          = false
      min_instance_count     = 1
      max_instance_count     = 5
      exec_migration         = true
      use_h2c                = false
      extra_env_vars         = {}
      extra_secret_env_vars  = {}
      installers_bucket_name = "fleet-test-installers"
    }
  }

  assert {
    condition = module.fleet_lifecycle.migration_identity_triggers == {
      image               = "fleetdm/fleet:v4.94.0"
      project             = "fleet-test-project"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet"
    }
    error_message = "A new image must change only the image part of the identity."
  }

  assert {
    condition     = nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].containers[0].image) == "fleetdm/fleet:v4.94.0" && nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].image) == "fleetdm/fleet:v4.94.0"
    error_message = "Job and service must both use the new image."
  }
}

run "database_name_change_changes_identity" {
  command = plan
  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  variables {
    database_config = {
      name                = "fleet-mysql"
      database_name       = "fleet_v2"
      database_user       = "fleet"
      collation           = "utf8mb4_unicode_ci"
      charset             = "utf8mb4"
      deletion_protection = false
      database_version    = "MYSQL_8_0"
      tier                = "db-n1-standard-1"
    }
  }

  assert {
    condition = module.fleet_lifecycle.migration_identity_triggers == {
      image               = "fleetdm/fleet:v4.93.0"
      project             = "fleet-test-project"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet_v2"
    }
    error_message = "A new logical database name must change only the database part of the identity."
  }

  assert {
    condition = [
      for e in nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].containers[0].env) :
      e.value if e.name == "FLEET_MYSQL_DATABASE"
    ] == ["fleet_v2"]
    error_message = "The migration job must prepare the new logical database."
  }
}

run "unrelated_changes_keep_identity" {
  command = plan
  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  variables {
    fleet_config = {
      image_tag              = "fleetdm/fleet:v4.93.0"
      fleet_cpu              = "2000m"
      fleet_memory           = "8192Mi"
      debug_logging          = true
      min_instance_count     = 2
      max_instance_count     = 10
      exec_migration         = true
      use_h2c                = false
      extra_env_vars         = { FLEET_EXAMPLE_SETTING = "1" }
      extra_secret_env_vars  = {}
      installers_bucket_name = "fleet-test-installers"
    }
    database_config = {
      name                = "fleet-mysql"
      database_name       = "fleet"
      database_user       = "fleet"
      collation           = "utf8mb4_unicode_ci"
      charset             = "utf8mb4"
      deletion_protection = false
      database_version    = "MYSQL_8_0"
      tier                = "db-custom-2-7680"
    }
    cache_config = {
      name           = "fleet-cache"
      tier           = "STANDARD_HA"
      engine_version = null
      connect_mode   = "PRIVATE_SERVICE_ACCESS"
      memory_size    = 2
    }
  }

  assert {
    condition = module.fleet_lifecycle.migration_identity_triggers == {
      image               = "fleetdm/fleet:v4.93.0"
      project             = "fleet-test-project"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet"
    }
    error_message = "CPU, memory, scaling, logging, extra env, SQL tier and Redis size changes must not change the migration identity."
  }
}

run "exec_migration_false_has_no_lifecycle_objects" {
  command = plan

  variables {
    fleet_config = {
      image_tag              = "fleetdm/fleet:v4.93.0"
      fleet_cpu              = "1000m"
      fleet_memory           = "4096Mi"
      debug_logging          = false
      min_instance_count     = 1
      max_instance_count     = 5
      exec_migration         = false
      use_h2c                = false
      extra_env_vars         = {}
      extra_secret_env_vars  = {}
      installers_bucket_name = "fleet-test-installers"
    }
  }

  assert {
    condition     = module.fleet_lifecycle.migration_identity_triggers == null && module.fleet_lifecycle.migration_job_name == null
    error_message = "exec_migration = false must not create identity/job/stop/restore objects."
  }

  assert {
    condition     = module.fleet_lifecycle.declared_scaling_mode == "AUTOMATIC" && nonsensitive(module.fleet_lifecycle.service.scaling[0].min_instance_count) == 1
    error_message = "exec_migration = false declares AUTOMATIC/min (operator runs migrations)."
  }
}
