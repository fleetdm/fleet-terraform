# No-cloud checks that the root module passes the per-service CMEK settings
# (cmek.cloud_sql/redis/cloud_run/secret_manager) through to byo-project and
# that the full stack, including the google-beta service identities, plans
# with the root google-beta provider configuration. module.fleet is NOT
# overridden here, so the child's validations and resources are exercised.
# Detailed and negative (expect_failures) checks on the child live in
# byo-project/tests/cmek_consumers.tftest.hcl, since a root test cannot expect
# failures from a child module.
#
# Every provider is mocked, so these runs never contact Google Cloud. Run from
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
  # Non-empty bucket name keeps the plan valid against the minimum (6.35)
  # google provider schema as well as the current one.
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

run "root_defaults_leave_new_consumers_off" {
  command = plan

  assert {
    condition = (
      var.cmek.enable == false &&
      var.cmek.cloud_sql == null &&
      var.cmek.redis == null &&
      var.cmek.cloud_run == null &&
      var.cmek.secret_manager == null
    )
    error_message = "All CMEK settings must default to off/null at the root."
  }
}

run "root_passes_all_consumers_through" {
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

  # Run and Memorystore service agents only exist once their APIs are on; the
  # opted-in API management enables them before module.fleet is planned.
  assert {
    condition = (
      contains(keys(google_project_service.existing_project_apis), "run.googleapis.com") &&
      contains(keys(google_project_service.existing_project_apis), "redis.googleapis.com") &&
      contains(keys(google_project_service.existing_project_apis), "sqladmin.googleapis.com") &&
      contains(keys(google_project_service.existing_project_apis), "secretmanager.googleapis.com")
    )
    error_message = "Opted-in API management must enable the APIs whose service agents receive KMS grants."
  }

  assert {
    condition     = length(var.cmek.secret_manager.replica_kms_key_ids) == 0
    error_message = "secret_manager.replica_kms_key_ids must default to an empty map."
  }
}
