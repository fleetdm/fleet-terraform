// Disk-backed /tmp: byo-project forwards var.tmp_volume_config to the
// fleet-lifecycle module and the service template carries the volume and
// mount. Plan only; every provider is mocked and nothing contacts Google
// Cloud. The rendering details and validation edge cases are covered in
// modules/fleet-lifecycle/tests/tmp_volume.tftest.hcl.

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

run "default_forwards_10gi_disk_tmp" {
  command = plan

  override_resource {
    target          = module.mysql.google_sql_database_instance.default
    override_during = plan
    values = {
      connection_name = "fleet-test-project:us-central1:fleet-mysql-0a1b2c3d"
    }
  }

  assert {
    condition = (
      length(nonsensitive(module.fleet_lifecycle.service.template[0].volumes)) == 1 &&
      nonsensitive(module.fleet_lifecycle.service.template[0].volumes[0].name) == "tmp" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].volumes[0].empty_dir[0].medium) == "DISK" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].volumes[0].empty_dir[0].size_limit) == "10Gi" &&
      length(nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].volume_mounts)) == 1 &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].volume_mounts[0].name) == "tmp" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].volume_mounts[0].mount_path) == "/tmp"
    )
    error_message = "Default: the Fleet service gets one 10Gi DISK empty_dir volume mounted at /tmp."
  }

  assert {
    condition     = output.cloud_run_tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    error_message = "output.cloud_run_tmp_volume must report the declared volume."
  }

  assert {
    condition = (
      nonsensitive(module.fleet_lifecycle.service.launch_stage) == "GA" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].execution_environment) == "EXECUTION_ENVIRONMENT_GEN2" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].resources[0].limits) == tomap({ cpu = "1000m", memory = "4096Mi" })
    )
    error_message = "GA, GEN2 and fleet_config's CPU/memory must be unchanged by the /tmp volume."
  }

  assert {
    condition = (
      length(nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].volumes)) == 0 &&
      length(nonsensitive(module.fleet_lifecycle.migration_job.template[0].template[0].containers[0].volume_mounts)) == 0
    )
    error_message = "The migration job must not get the /tmp volume."
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
    error_message = "The migration identity must be unchanged by the /tmp setting."
  }
}

run "custom_size_forwarded" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 20 }
  }

  assert {
    condition = (
      nonsensitive(module.fleet_lifecycle.service.template[0].volumes[0].empty_dir[0].size_limit) == "20Gi" &&
      output.cloud_run_tmp_volume == { name = "tmp", medium = "DISK", size_limit = "20Gi", mount_path = "/tmp" }
    )
    error_message = "tmp_volume_config.size_gib = 20 must reach the service as 20Gi."
  }
}

run "opt_out_forwarded" {
  command = plan

  variables {
    tmp_volume_config = { enable = false }
  }

  assert {
    condition = (
      length(nonsensitive(module.fleet_lifecycle.service.template[0].volumes)) == 0 &&
      length(nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].volume_mounts)) == 0 &&
      output.cloud_run_tmp_volume == null
    )
    error_message = "enable = false must reach the service: no volume and no mount."
  }

  assert {
    condition = (
      nonsensitive(module.fleet_lifecycle.service.launch_stage) == "GA" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].execution_environment) == "EXECUTION_ENVIRONMENT_GEN2" &&
      nonsensitive(module.fleet_lifecycle.service.template[0].containers[0].resources[0].limits) == tomap({ cpu = "1000m", memory = "4096Mi" })
    )
    error_message = "Opting out must leave GA, GEN2 and the limits unchanged."
  }
}

run "size_zero_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 0 }
  }
  expect_failures = [var.tmp_volume_config]
}

run "size_fraction_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 2.5 }
  }
  expect_failures = [var.tmp_volume_config]
}

run "size_above_100_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 101 }
  }
  expect_failures = [var.tmp_volume_config]
}
