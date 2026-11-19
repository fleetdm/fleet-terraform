// Disk-backed /tmp (var.tmp_volume_config), plan only, mocked providers.
//
// The feature is opt-in: the default (and every omitted/null attribute)
// declares no volume and no mount, so /tmp stays Cloud Run's in-memory
// filesystem. Only enable = true renders one empty_dir volume with medium
// DISK and the size limit, mounted at /tmp in the Fleet container. Also
// checks that the setting leaves the migration job, the migration identity,
// GA/GEN2 and the container memory alone. What real Cloud Run does with the
// volume (quota, billing, lifetime) is not shown by mocks; the loopback
// integration harness checks the request the real google-beta provider sends.
mock_provider "google-beta" {}
mock_provider "terracurl" {}
mock_provider "time" {}

variables {
  project_id            = "fictional-proj"
  region                = "us-central1"
  image                 = "fleetdm/fleet:v4.93.0"
  service_account_email = "fleet-run-sa@fictional-proj.iam.gserviceaccount.com"
  vpc_network           = "fleet-network"
  vpc_subnetwork        = "fleet-subnet"
  cpu                   = "1000m"
  memory                = "4096Mi"
  min_instance_count    = 1
  max_instance_count    = 5
  database_identity     = { sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d", database_name = "fleet" }
}

// ---------------------------------------------------------------- off (default)

// No tmp_volume_config at all: the feature is off.
run "default_is_off_no_volume_no_mount" {
  command = plan

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts) == 0 &&
      output.tmp_volume == null
    )
    error_message = "Default: no volume and no mount (Cloud Run's in-memory /tmp), and output.tmp_volume is null."
  }

  // Unchanged service behaviour: GA launch stage, GEN2 (ephemeral disk would
  // need it), container memory/CPU as configured.
  assert {
    condition = (
      google_cloud_run_v2_service.fleet.launch_stage == "GA" &&
      google_cloud_run_v2_service.fleet.template[0].execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits == tomap({ cpu = "1000m", memory = "4096Mi" })
    )
    error_message = "The off default must not change launch_stage (GA), the GEN2 environment or the container limits."
  }

  // The migration job never gets a volume or a mount, with the feature off.
  assert {
    condition = (
      length(google_cloud_run_v2_job.migration) == 1 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].volumes) == 0 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].volume_mounts) == 0
    )
    error_message = "The migration job must not declare a /tmp volume or mount."
  }

  assert {
    condition = terraform_data.identity[0].triggers_replace == {
      image               = "fleetdm/fleet:v4.93.0"
      project             = "fictional-proj"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet"
    }
    error_message = "The /tmp setting must not be part of the migration identity."
  }
}

// Explicit false is the same as the default.
run "explicit_false_declares_no_volume_and_no_mount" {
  command = plan

  variables {
    tmp_volume_config = { enable = false }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts) == 0 &&
      output.tmp_volume == null
    )
    error_message = "enable = false must declare neither the volume nor the mount (in-memory /tmp)."
  }

  assert {
    condition = (
      google_cloud_run_v2_service.fleet.launch_stage == "GA" &&
      google_cloud_run_v2_service.fleet.template[0].execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits == tomap({ cpu = "1000m", memory = "4096Mi" }) &&
      length(google_cloud_run_v2_job.migration) == 1 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].volumes) == 0
    )
    error_message = "Turning the feature off must leave GA, GEN2, the limits and the migration job as they are."
  }
}

// An empty object, and explicit nulls, take the type defaults: false and 10.
run "empty_object_is_off" {
  command = plan

  variables {
    tmp_volume_config = {}
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts) == 0 &&
      output.tmp_volume == null
    )
    error_message = "tmp_volume_config = {} must be off: no volume, no mount, null output."
  }
}

run "null_attributes_take_defaults_off" {
  command = plan

  variables {
    tmp_volume_config = { enable = null, size_gib = null }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 &&
      output.tmp_volume == null
    )
    error_message = "Null enable/size_gib must fall back to the defaults false/10, so the feature stays off."
  }
}

// size_gib alone must not turn the feature on.
run "size_alone_does_not_enable" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 20 }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts) == 0 &&
      output.tmp_volume == null
    )
    error_message = "size_gib without enable = true leaves the feature off: no volume, no mount, null output."
  }
}

// ------------------------------------------------------------------- opted in

run "opt_in_is_10gi_disk_at_tmp" {
  command = plan

  variables {
    tmp_volume_config = { enable = true }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 1 &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].name == "tmp" &&
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir) == 1 &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].medium == "DISK" &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "10Gi"
    )
    error_message = "enable = true: exactly one volume `tmp`, empty_dir medium DISK, size_limit 10Gi (the default size)."
  }

  // Only the volume source is set: no secret, Cloud SQL, GCS or NFS source.
  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].secret) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].cloud_sql_instance) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].gcs) == 0 &&
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].nfs) == 0
    )
    error_message = "The /tmp volume must be an empty_dir only."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].containers) == 1 &&
      length(google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts) == 1 &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts[0].name == "tmp" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts[0].mount_path == "/tmp" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts[0].sub_path == null
    )
    error_message = "enable = true: the Fleet container mounts volume `tmp` at /tmp (no sub_path)."
  }

  assert {
    condition     = output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    error_message = "output.tmp_volume must report the declared volume and mount."
  }

  // Unchanged service behaviour: GA launch stage, GEN2 (ephemeral disk needs
  // it), container memory/CPU not raised for the volume.
  assert {
    condition = (
      google_cloud_run_v2_service.fleet.launch_stage == "GA" &&
      google_cloud_run_v2_service.fleet.template[0].execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits == tomap({ cpu = "1000m", memory = "4096Mi" })
    )
    error_message = "Opting in must not change launch_stage (GA), the GEN2 environment or the container limits."
  }

  // The migration job never gets the volume or a mount.
  assert {
    condition = (
      length(google_cloud_run_v2_job.migration) == 1 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].volumes) == 0 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].volume_mounts) == 0
    )
    error_message = "The migration job must not declare a /tmp volume or mount."
  }

  assert {
    condition = terraform_data.identity[0].triggers_replace == {
      image               = "fleetdm/fleet:v4.93.0"
      project             = "fictional-proj"
      region              = "us-central1"
      service             = "fleet-api"
      sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d"
      database            = "fleet"
    }
    error_message = "The /tmp setting must not be part of the migration identity."
  }
}

run "opt_in_custom_size_20gi" {
  command = plan

  variables {
    tmp_volume_config = { enable = true, size_gib = 20 }
  }

  assert {
    condition = (
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].medium == "DISK" &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "20Gi" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts[0].mount_path == "/tmp"
    )
    error_message = "enable = true with size_gib = 20 must render a 20Gi DISK volume at /tmp."
  }

  assert {
    condition     = output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "20Gi", mount_path = "/tmp" }
    error_message = "output.tmp_volume must report 20Gi."
  }

  assert {
    condition     = terraform_data.identity[0].triggers_replace.image == "fleetdm/fleet:v4.93.0" && length(terraform_data.identity[0].triggers_replace) == 6
    error_message = "Resizing /tmp must not change the migration identity inputs."
  }
}

// Null size with enable = true takes the 10 GiB default.
run "opt_in_null_size_defaults_to_10gi" {
  command = plan

  variables {
    tmp_volume_config = { enable = true, size_gib = null }
  }

  assert {
    condition     = output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    error_message = "A null size_gib with enable = true must fall back to 10."
  }
}

run "opt_in_upper_bound_100_accepted" {
  command = plan

  variables {
    tmp_volume_config = { enable = true, size_gib = 100 }
  }

  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "100Gi"
    error_message = "100 GiB is the Cloud Run per-volume maximum and must be accepted."
  }
}

run "opt_in_lower_bound_1_accepted" {
  command = plan

  variables {
    tmp_volume_config = { enable = true, size_gib = 1 }
  }

  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "1Gi"
    error_message = "1 GiB is the Cloud Run per-volume minimum and must be accepted."
  }
}

run "opt_in_with_migration_disabled_still_mounts_tmp" {
  command = plan

  variables {
    migration_enabled = false
    tmp_volume_config = { enable = true }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.migration) == 0 &&
      output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    )
    error_message = "The /tmp volume belongs to the service, independent of the migration gate."
  }
}

// ------------------------------------------------------------------ validation

run "size_zero_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 0 }
  }
  expect_failures = [var.tmp_volume_config]
}

run "size_negative_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = -5 }
  }
  expect_failures = [var.tmp_volume_config]
}

run "size_fraction_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 10.5 }
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

// The size is validated even when the volume is off, so a later enable = true
// cannot surface an invalid size for the first time.
run "size_validated_when_disabled" {
  command = plan
  variables {
    tmp_volume_config = { enable = false, size_gib = 0 }
  }
  expect_failures = [var.tmp_volume_config]
}
