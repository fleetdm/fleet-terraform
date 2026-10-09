// Plan-only checks that the Cloud Run service and migration job secret
// readiness gate (depends_on in cloud_run.tf) stays valid for both the
// managed and the external (fleet_server_private_key_secret) private-key
// paths. Uses mock providers, so no GCP credentials are needed and nothing
// is created. Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Mock plans cannot prove apply-time ordering; the ordering itself comes from
// the depends_on lists and is visible in `terraform graph`.

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

run "managed_private_key_creates_secret_version" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = length(google_secret_manager_secret.private_key) == 1
    error_message = "Managed private-key path must create the private-key secret."
  }

  assert {
    condition     = length(google_secret_manager_secret_version.private_key) == 1
    error_message = "Managed private-key path must create the private-key secret version the Cloud Run gate waits on."
  }

  assert {
    condition     = length(data.google_secret_manager_secret.external_private_key) == 0
    error_message = "Managed private-key path must not look up an external secret."
  }
}

run "external_private_key_has_no_managed_version" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    fleet_config = {
      image_tag                       = "fleetdm/fleet:v4.93.0"
      fleet_cpu                       = "1000m"
      fleet_memory                    = "4096Mi"
      debug_logging                   = false
      fleet_server_private_key_secret = "existing-fleet-private-key"
      min_instance_count              = 1
      max_instance_count              = 5
      exec_migration                  = true
      use_h2c                         = false
      extra_env_vars                  = {}
      extra_secret_env_vars           = {}
      installers_bucket_name          = "fleet-test-installers"
    }
  }

  override_data {
    target = data.google_secret_manager_secret.external_private_key[0]
    values = {
      id        = "projects/fleet-test-project/secrets/existing-fleet-private-key"
      secret_id = "existing-fleet-private-key"
    }
  }

  // The depends_on gate references the private-key version collection as a
  // whole, so count = 0 must plan cleanly without creating a managed version.
  assert {
    condition     = length(google_secret_manager_secret.private_key) == 0
    error_message = "External private-key path must not create a managed private-key secret."
  }

  assert {
    condition     = length(google_secret_manager_secret_version.private_key) == 0
    error_message = "External private-key path must not create a managed private-key secret version."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access.secret_id == "projects/fleet-test-project/secrets/existing-fleet-private-key"
    error_message = "External private-key path must grant secretAccessor on the external secret."
  }
}
