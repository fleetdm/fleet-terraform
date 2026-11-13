// Disk-backed /tmp (var.tmp_volume_config), plan only, mocked providers.
//
// Asserts the rendered service template: one empty_dir volume with medium
// DISK and the size limit, mounted at /tmp in the Fleet container; nothing
// when disabled. Also checks that the setting leaves the migration job, the
// migration identity, GA/GEN2 and the container memory alone. What real
// Cloud Run does with the volume (quota, billing, lifetime) is not shown by
// mocks; the loopback integration harness checks the request the real
// google-beta provider sends.
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

run "default_is_10gi_disk_at_tmp" {
  command = plan

  assert {
    condition = (
      length(google_cloud_run_v2_service.fleet.template[0].volumes) == 1 &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].name == "tmp" &&
      length(google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir) == 1 &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].medium == "DISK" &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "10Gi"
    )
    error_message = "Default: exactly one volume `tmp`, empty_dir medium DISK, size_limit 10Gi."
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
    error_message = "Default: the Fleet container mounts volume `tmp` at /tmp (no sub_path)."
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
    error_message = "The /tmp volume must not change launch_stage (GA), the GEN2 environment or the container limits."
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

run "custom_size_20gi" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 20 }
  }

  assert {
    condition = (
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].medium == "DISK" &&
      google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "20Gi" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts[0].mount_path == "/tmp"
    )
    error_message = "size_gib = 20 must render a 20Gi DISK volume at /tmp."
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

run "upper_bound_100_accepted" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 100 }
  }

  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "100Gi"
    error_message = "100 GiB is the Cloud Run per-volume maximum and must be accepted."
  }
}

run "lower_bound_1_accepted" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 1 }
  }

  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit == "1Gi"
    error_message = "1 GiB is the Cloud Run per-volume minimum and must be accepted."
  }
}

// Explicit nulls take the defaults (optional attribute defaults).
run "null_attributes_take_defaults" {
  command = plan

  variables {
    tmp_volume_config = { enable = null, size_gib = null }
  }

  assert {
    condition     = output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    error_message = "Null enable/size_gib must fall back to true/10."
  }
}

run "opt_out_declares_no_volume_and_no_mount" {
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
    error_message = "enable = false must declare neither the volume nor the mount (in-memory /tmp as before)."
  }

  assert {
    condition = (
      google_cloud_run_v2_service.fleet.launch_stage == "GA" &&
      google_cloud_run_v2_service.fleet.template[0].execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits == tomap({ cpu = "1000m", memory = "4096Mi" }) &&
      length(google_cloud_run_v2_job.migration) == 1 &&
      length(google_cloud_run_v2_job.migration[0].template[0].template[0].volumes) == 0
    )
    error_message = "Opting out must leave GA, GEN2, the limits and the migration job as they are."
  }
}

run "migration_disabled_still_mounts_tmp" {
  command = plan

  variables {
    migration_enabled = false
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.migration) == 0 &&
      output.tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    )
    error_message = "The /tmp volume belongs to the service, independent of the migration gate."
  }
}

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
