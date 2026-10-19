# No-cloud checks for the root cmek_iam_propagation_delay_seconds input: its
# default, root-level validation, and that the full stack (module.fleet is
# NOT overridden) plans with the forwarded value for default, custom and zero
# delays. The time_sleep itself, its triggers and per-consumer behavior are
# asserted in byo-project/tests/cmek_iam_propagation_delay.tftest.hcl, since a
# root test cannot address child-module resources.
#
# Every provider is mocked, so these runs never contact Google Cloud and never
# sleep. Run from the gcp/ directory:
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

run "root_default_delay_is_120" {
  command = plan

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 120
    error_message = "cmek_iam_propagation_delay_seconds must default to 120 at the root."
  }
}

run "root_default_delay_with_all_consumers" {
  command = plan

  variables {
    manage_existing_project_apis = true
    cmek = {
      cloud_sql      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" }
      redis          = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" }
      cloud_run      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" }
      secret_manager = { kms_key_id = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" }
    }
  }

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 120
    error_message = "Default delay must be forwarded as 120."
  }
}

run "root_custom_delay_with_consumer" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = 300
    cmek                               = { redis = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" } }
  }

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 300
    error_message = "Custom delay must be accepted at the root."
  }
}

run "root_zero_delay_with_consumer" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = 0
    cmek                               = { cloud_run = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" } }
  }

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 0
    error_message = "Zero delay must be accepted at the root."
  }
}

run "root_null_delay_uses_default" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = null
  }

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 120
    error_message = "A null delay must fall back to 120 seconds at the root."
  }
}

run "root_reject_negative_delay" {
  command = plan
  variables {
    cmek_iam_propagation_delay_seconds = -5
  }
  expect_failures = [var.cmek_iam_propagation_delay_seconds]
}

run "root_reject_fractional_delay" {
  command = plan
  variables {
    cmek_iam_propagation_delay_seconds = 0.5
  }
  expect_failures = [var.cmek_iam_propagation_delay_seconds]
}
