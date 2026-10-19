// Plan-only checks for software installers bucket versioning and
// noncurrent-version retention (software_installers_config). Uses mock
// providers, so no GCP credentials are needed and nothing is created.
// Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Contract under test (AWS module parity):
//   * versioning is off by default and no lifecycle rule is created
//   * enabling versioning defaults to deleting noncurrent versions after 30 days
//   * expire_noncurrent_versions = false keeps every noncurrent version
//   * the expiry window is configurable and must be a positive whole number
//   * the expiry rule only matches ARCHIVED (noncurrent) objects, never live ones
//   * the bucket name and CMEK wiring are unchanged
//
// google-beta is only required by child registry modules, so every run maps
// the mocks explicitly; otherwise the real google-beta provider is used.

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

run "default_versioning_off_no_expiry" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = var.software_installers_config.enable_bucket_versioning == false
    error_message = "Installer bucket versioning must be off by default."
  }

  assert {
    condition     = google_storage_bucket.software_installers.versioning[0].enabled == false
    error_message = "Default installer bucket must be planned with versioning disabled."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.lifecycle_rule) == 0
    error_message = "With versioning off, no noncurrent-version expiry rule may be created."
  }

  assert {
    condition     = google_storage_bucket.software_installers.name == "fleet-test-installers"
    error_message = "Installer bucket name must still come from fleet_config.installers_bucket_name."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.encryption) == 0
    error_message = "Default (CMEK disabled) installer bucket must not set a KMS key."
  }
}

run "versioning_on_defaults_to_30_day_noncurrent_expiry" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning = true
    }
  }

  assert {
    condition     = google_storage_bucket.software_installers.versioning[0].enabled == true
    error_message = "enable_bucket_versioning = true must enable bucket versioning."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.lifecycle_rule) == 1
    error_message = "Versioning on must default to exactly one noncurrent-version expiry rule."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].action).type == "Delete"
    error_message = "The noncurrent-version rule must delete expired versions."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].condition).days_since_noncurrent_time == 30
    error_message = "Noncurrent versions must expire after 30 days by default."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].condition).with_state == "ARCHIVED"
    error_message = "The expiry rule must match only noncurrent (ARCHIVED) objects so live objects are never deleted."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].condition).age == null
    error_message = "The expiry rule must not use an age condition, which would also match live objects."
  }

  assert {
    condition     = google_storage_bucket.software_installers.name == "fleet-test-installers"
    error_message = "Enabling versioning must not change the installer bucket name."
  }
}

run "versioning_on_expiry_opt_out_keeps_all_versions" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning   = true
      expire_noncurrent_versions = false
    }
  }

  assert {
    condition     = google_storage_bucket.software_installers.versioning[0].enabled == true
    error_message = "Opting out of expiry must keep versioning enabled."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.lifecycle_rule) == 0
    error_message = "expire_noncurrent_versions = false must not create an expiry rule."
  }
}

run "versioning_off_ignores_expiry_settings" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = false
      expire_noncurrent_versions         = true
      noncurrent_version_expiration_days = 7
    }
  }

  assert {
    condition     = google_storage_bucket.software_installers.versioning[0].enabled == false
    error_message = "enable_bucket_versioning = false must leave versioning disabled."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.lifecycle_rule) == 0
    error_message = "Expiry is gated on versioning; with versioning off no rule may be created."
  }
}

run "versioning_on_custom_expiry_days" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 90
    }
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.lifecycle_rule) == 1
    error_message = "A custom expiry window must still create exactly one rule."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].condition).days_since_noncurrent_time == 90
    error_message = "noncurrent_version_expiration_days must set the noncurrent expiry window."
  }

  assert {
    condition     = one(google_storage_bucket.software_installers.lifecycle_rule[0].condition).with_state == "ARCHIVED"
    error_message = "A custom expiry window must still match only noncurrent (ARCHIVED) objects."
  }
}

run "zero_expiry_days_rejected" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 0
    }
  }

  expect_failures = [var.software_installers_config]
}

run "negative_expiry_days_rejected" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = -5
    }
  }

  expect_failures = [var.software_installers_config]
}

run "fractional_expiry_days_rejected" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 1.5
    }
  }

  expect_failures = [var.software_installers_config]
}
