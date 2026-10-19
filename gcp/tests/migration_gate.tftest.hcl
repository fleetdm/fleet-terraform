# No-cloud checks that the full stack (module.fleet is NOT overridden) plans
# with the database migration gate enabled and disabled. The gate's triggers
# and job settings are asserted in byo-project/tests/migration_gate.tftest.hcl,
# since a root test cannot address child-module resources.
#
# These runs MUST stay `command = plan`: the gate is a local-exec provisioner,
# which mock providers cannot intercept. Every provider is mocked. Run from
# the gcp/ directory:
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

run "root_plans_with_migration_gate" {
  command = plan

  assert {
    condition     = nonsensitive(var.fleet_config.exec_migration) == true
    error_message = "exec_migration must be forwarded as true."
  }
}

run "root_plans_without_migration_gate" {
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
    condition     = nonsensitive(var.fleet_config.exec_migration) == false
    error_message = "exec_migration must be forwarded as false."
  }
}
