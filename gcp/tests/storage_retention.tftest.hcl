# No-cloud checks for the root-level software_installers_config input contract
# (installer bucket versioning and noncurrent-version retention, AWS parity):
#   * versioning off by default
#   * enabling versioning defaults to expiring noncurrent versions after 30 days
#   * expiry can be opted out of, and the window changed
#   * the window must be a positive whole number of days
#
# Every provider is mocked, so these runs never contact Google Cloud. Input
# contract runs override module.fleet; the last runs plan the real child module
# to prove the root value is accepted by module.fleet. Bucket rendering
# (versioning, lifecycle rule, ARCHIVED-only matching) is covered by
# byo-project/tests/storage_retention.tftest.hcl. Run from the gcp/ directory:
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
  project_id      = "my-existing-project"
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

run "root_versioning_off_by_default" {
  command = plan

  override_module {
    target = module.fleet
  }

  assert {
    condition     = var.software_installers_config.enable_bucket_versioning == false
    error_message = "Installer bucket versioning must be off by default."
  }

  assert {
    condition     = var.software_installers_config.expire_noncurrent_versions == true
    error_message = "Noncurrent-version expiry must default on (it only applies once versioning is enabled)."
  }

  assert {
    condition     = var.software_installers_config.noncurrent_version_expiration_days == 30
    error_message = "Noncurrent versions must default to a 30-day expiry window."
  }
}

run "root_null_config_uses_defaults" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = null
  }

  assert {
    condition     = var.software_installers_config.enable_bucket_versioning == false && var.software_installers_config.noncurrent_version_expiration_days == 30
    error_message = "A null software_installers_config must fall back to the defaults."
  }
}

run "root_versioning_on_defaults_to_30_day_expiry" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning = true
    }
  }

  assert {
    condition     = var.software_installers_config.enable_bucket_versioning == true
    error_message = "enable_bucket_versioning = true must be accepted."
  }

  assert {
    condition     = var.software_installers_config.expire_noncurrent_versions == true && var.software_installers_config.noncurrent_version_expiration_days == 30
    error_message = "Enabling versioning must default to expiring noncurrent versions after 30 days."
  }
}

run "root_expiry_opt_out" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning   = true
      expire_noncurrent_versions = false
    }
  }

  assert {
    condition     = var.software_installers_config.expire_noncurrent_versions == false
    error_message = "expire_noncurrent_versions = false must be accepted."
  }
}

run "root_custom_expiry_days" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 90
    }
  }

  assert {
    condition     = var.software_installers_config.noncurrent_version_expiration_days == 90
    error_message = "A custom noncurrent_version_expiration_days must be accepted."
  }
}

run "root_zero_expiry_days_rejected" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 0
    }
  }

  expect_failures = [var.software_installers_config]
}

run "root_fractional_expiry_days_rejected" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 2.5
    }
  }

  expect_failures = [var.software_installers_config]
}

# Plan the real child module so module.fleet must accept the root value.
run "root_default_plans_full_stack" {
  command = plan

  assert {
    condition     = output.software_installers_bucket_name == nonsensitive(var.fleet_config.installers_bucket_name)
    error_message = "The installer bucket name must still come from fleet_config.installers_bucket_name."
  }
}

run "root_versioning_on_custom_expiry_plans_full_stack" {
  command = plan

  variables {
    software_installers_config = {
      enable_bucket_versioning           = true
      noncurrent_version_expiration_days = 45
    }
  }

  assert {
    condition     = output.software_installers_bucket_name == nonsensitive(var.fleet_config.installers_bucket_name)
    error_message = "Enabling versioning must not change the installer bucket name."
  }
}
