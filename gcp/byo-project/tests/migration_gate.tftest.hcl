// Plan-only checks for the database migration gate wiring in cloud_run.tf.
// Every provider is mocked, so nothing contacts Google Cloud. These runs MUST
// stay `command = plan`: the gate is a local-exec provisioner, which a mock
// provider cannot intercept, so an apply would start the real controller.
// Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Ordering (job and module.mysql -> gate -> service) comes from depends_on and
// is visible in `terraform graph`; the controller protocol itself is covered by
// the offline Python tests in scripts/tests.
//
// Database identity: the sql_instance trigger is the Cloud SQL instance's
// connection_name. Re-running on an instance replacement relies on the real
// provider planning that computed attribute as unknown for a replacement. A
// mock provider cannot show that, so these tests only check the wiring. The
// runs that need a known connection_name set it with override_during = plan;
// that value is test input, not provider behavior.

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
mock_provider "terracurl" {}
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

run "gate_enabled_by_default" {
  command = plan

  assert {
    condition     = length(terraform_data.fleet_migration_gate) == 1
    error_message = "exec_migration = true must create the migration gate."
  }

  assert {
    condition     = terraform_data.fleet_migration_gate[0].triggers_replace.image == "fleetdm/fleet:v4.93.0"
    error_message = "The gate must re-run when the Fleet image changes (image trigger)."
  }

  assert {
    condition = (
      terraform_data.fleet_migration_gate[0].triggers_replace.project == "fleet-test-project" &&
      terraform_data.fleet_migration_gate[0].triggers_replace.region == "us-central1" &&
      terraform_data.fleet_migration_gate[0].triggers_replace.service == "fleet-api" &&
      terraform_data.fleet_migration_gate[0].triggers_replace.job == "fleet-migration"
    )
    error_message = "Gate triggers must identify the project, region, service and job."
  }

  // Scope: the gate re-runs for initial setup, image changes and target
  // database identity changes only.
  assert {
    condition     = toset(keys(terraform_data.fleet_migration_gate[0].triggers_replace)) == toset(["image", "project", "region", "service", "job", "sql_instance", "database"])
    error_message = "Gate triggers must be exactly image, project, region, service, job, sql_instance and database."
  }

  assert {
    condition     = terraform_data.fleet_migration_gate[0].triggers_replace.database == "fleet"
    error_message = "The gate must be keyed on the target logical database name."
  }

  assert {
    condition     = module.fleet-service.service_name == "fleet-api"
    error_message = "The gate addresses the service by the literal name fleet-api; the module must use the same name."
  }
}

run "job_is_single_task_single_attempt" {
  command = plan

  assert {
    condition = (
      google_cloud_run_v2_job.fleet_migration_job.template[0].task_count == 1 &&
      google_cloud_run_v2_job.fleet_migration_job.template[0].parallelism == 1 &&
      google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].max_retries == 0
    )
    error_message = "The migration job must be one task, parallelism 1, max_retries 0."
  }

  assert {
    condition     = google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].containers[0].args == tolist(["prepare", "db", "--no-prompt=true"])
    error_message = "The migration job must still run `fleet prepare db`."
  }

  // The gate copies the serving env and CMEK key from the job into the
  // service before Fleet restarts, so the job must carry the service's env
  // (same locals), including the database and Redis endpoints and secrets.
  assert {
    condition = alltrue([
      for n in ["FLEET_MYSQL_ADDRESS", "FLEET_MYSQL_DATABASE", "FLEET_REDIS_ADDRESS", "FLEET_MYSQL_PASSWORD", "FLEET_SERVER_PRIVATE_KEY"] :
      contains([for e in nonsensitive(google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].containers[0].env) : e.name], n)
    ])
    error_message = "The migration job must carry the Fleet serving env (MySQL/Redis endpoints and secret references)."
  }
}

run "image_change_changes_the_trigger" {
  command = plan

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
    condition     = terraform_data.fleet_migration_gate[0].triggers_replace.image == "fleetdm/fleet:v4.94.0"
    error_message = "A new image must change the gate trigger so the gate is replaced and re-runs."
  }

  assert {
    condition     = google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].containers[0].image == "fleetdm/fleet:v4.94.0"
    error_message = "The job must be updated to the new image before the gate runs it."
  }
}

run "exec_migration_false_has_no_gate" {
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
    condition     = length(terraform_data.fleet_migration_gate) == 0
    error_message = "exec_migration = false must not create the gate (migrations are the operator's responsibility)."
  }

  assert {
    condition     = google_cloud_run_v2_job.fleet_migration_job.name == "fleet-migration"
    error_message = "The migration job is still created for manual use."
  }
}

// The sql_instance trigger is the instance's connection_name, so a new
// instance (initial provisioning, or a replacement, including one that keeps
// the same name) changes the trigger. The connection name below is test input
// (override_during = plan), not provider output.
run "sql_instance_trigger_is_the_connection_name" {
  command = plan

  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  assert {
    condition     = module.mysql.instance_connection_name == "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    error_message = "Test setup: the sql-db module must expose the instance connection_name as instance_connection_name."
  }

  assert {
    condition     = terraform_data.fleet_migration_gate[0].triggers_replace.sql_instance == module.mysql.instance_connection_name
    error_message = "The gate's sql_instance trigger must be the Cloud SQL instance connection_name."
  }

  assert {
    condition = terraform_data.fleet_migration_gate[0].triggers_replace == {
      image        = "fleetdm/fleet:v4.93.0"
      project      = "fleet-test-project"
      region       = "us-central1"
      service      = "fleet-api"
      job          = "fleet-migration"
      sql_instance = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database     = "fleet"
    }
    error_message = "Baseline gate trigger contract changed."
  }
}

// A new logical database (a different database_config.database_name) is a new
// migration target: the trigger changes and the job prepares that database.
run "database_name_change_changes_the_trigger" {
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
    condition = terraform_data.fleet_migration_gate[0].triggers_replace == {
      image        = "fleetdm/fleet:v4.93.0"
      project      = "fleet-test-project"
      region       = "us-central1"
      service      = "fleet-api"
      job          = "fleet-migration"
      sql_instance = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database     = "fleet_v2"
    }
    error_message = "A new logical database name must change only the database trigger (same image, same instance)."
  }

  assert {
    condition = [
      for e in nonsensitive(google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].containers[0].env) :
      e.value if e.name == "FLEET_MYSQL_DATABASE"
    ] == ["fleet_v2"]
    error_message = "The migration job must prepare the new logical database."
  }
}

// Settings that do not change the migration target must not re-run the gate.
// The expected trigger is identical to the baseline run above.
run "unrelated_changes_keep_the_trigger" {
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
    condition = terraform_data.fleet_migration_gate[0].triggers_replace == {
      image        = "fleetdm/fleet:v4.93.0"
      project      = "fleet-test-project"
      region       = "us-central1"
      service      = "fleet-api"
      job          = "fleet-migration"
      sql_instance = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
      database     = "fleet"
    }
    error_message = "CPU, memory, scaling, logging, extra env, SQL tier and Redis size changes must not change the gate trigger."
  }
}
