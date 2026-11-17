# Disk-backed /tmp (opt-in): the root forwards var.tmp_volume_config through
# ./byo-project to the Fleet Cloud Run service. module.fleet is NOT
# overridden, so output.cloud_run_tmp_volume is read from the planned service
# resource itself (a root test cannot address child-module resources): an
# assertion on it proves the root -> byo-project -> fleet-lifecycle forwarding
# and the rendered service entry together. The template details and the
# migration job are asserted in byo-project/tests/tmp_volume.tftest.hcl and
# byo-project/modules/fleet-lifecycle/tests/tmp_volume.tftest.hcl.
#
# Every provider is mocked. Run from the gcp/ directory:
#
#   terraform init -backend=false
#   terraform test

mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b"]
    }
  }
}

mock_provider "google-beta" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b"]
    }
  }
}
mock_provider "random" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "terracurl" {}

variables {
  create_project  = false
  project_id      = "fleet-existing-1234"
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

# ---------------------------------------------------------------- off (default)

run "default_is_off" {
  command = plan

  assert {
    condition     = output.cloud_run_tmp_volume == null
    error_message = "Without tmp_volume_config the service must declare no /tmp volume (in-memory /tmp)."
  }
}

run "explicit_false_is_off" {
  command = plan

  variables {
    tmp_volume_config = { enable = false }
  }

  assert {
    condition     = output.cloud_run_tmp_volume == null
    error_message = "tmp_volume_config.enable = false must leave the service without a /tmp volume."
  }
}

# size_gib on its own must not enable the feature.
run "size_alone_does_not_enable" {
  command = plan

  variables {
    tmp_volume_config = { size_gib = 20 }
  }

  assert {
    condition     = output.cloud_run_tmp_volume == null
    error_message = "tmp_volume_config = { size_gib = 20 } without enable = true must stay off."
  }
}

# ------------------------------------------------------------------- opted in

run "opt_in_is_10gi_disk_tmp" {
  command = plan

  variables {
    tmp_volume_config = { enable = true }
  }

  assert {
    condition     = output.cloud_run_tmp_volume == { name = "tmp", medium = "DISK", size_limit = "10Gi", mount_path = "/tmp" }
    error_message = "tmp_volume_config.enable = true must reach the service as a 10Gi DISK volume at /tmp."
  }
}

run "opt_in_custom_size_reaches_service" {
  command = plan

  variables {
    tmp_volume_config = { enable = true, size_gib = 20 }
  }

  assert {
    condition     = output.cloud_run_tmp_volume == { name = "tmp", medium = "DISK", size_limit = "20Gi", mount_path = "/tmp" }
    error_message = "enable = true with size_gib = 20 must reach the service as 20Gi."
  }
}

# ------------------------------------------------------------------ validation

run "size_zero_rejected" {
  command = plan
  variables {
    tmp_volume_config = { size_gib = 0 }
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
