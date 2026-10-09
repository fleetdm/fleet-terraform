# No-cloud regression tests for backward-compatible GCP defaults.
#
# Every provider is mocked and the heavy child modules are overridden, so these
# runs never contact Google Cloud. Run from the gcp/ directory:
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

override_module {
  target = module.project_factory
  outputs = {
    project_id = "fleet-legacy-1234"
  }
}

override_module {
  target = module.fleet
}

variables {
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

# Legacy root configs never set create_project; they must keep creating the
# project through the project factory (now addressed as project_factory[0]).
run "legacy_config_creates_project_by_default" {
  command = plan

  variables {
    org_id             = "123456789012"
    billing_account_id = "AAAAAA-BBBBBB-CCCCCC"
  }

  assert {
    condition     = var.create_project == true
    error_message = "create_project must default to true for backward compatibility."
  }

  assert {
    condition     = length(module.project_factory) == 1
    error_message = "Default configuration must create the project via project_factory."
  }

  assert {
    condition     = local.effective_project_id == "fleet-legacy-1234"
    error_message = "Fleet must deploy into the project_factory project by default."
  }

  assert {
    condition     = var.database_config.name == "fleet-mysql"
    error_message = "Default Cloud SQL instance name must stay fleet-mysql to avoid replacement."
  }

  assert {
    condition     = var.labels == tomap({ application = "fleet" })
    error_message = "Default labels changed unexpectedly."
  }
}

# The explicit bring-your-own-project path must remain supported.
run "explicit_existing_project" {
  command = plan

  variables {
    create_project = false
    project_id     = "my-existing-project"
  }

  assert {
    condition     = length(module.project_factory) == 0
    error_message = "create_project=false must not create a project."
  }

  assert {
    condition     = local.effective_project_id == "my-existing-project"
    error_message = "create_project=false must deploy into the supplied project_id."
  }
}

run "create_project_requires_billing_and_parent" {
  command = plan

  expect_failures = [var.create_project]
}

run "existing_project_requires_project_id" {
  command = plan

  variables {
    create_project = false
  }

  expect_failures = [var.project_id]
}

# The byo-project module is also consumed directly; its default Cloud SQL
# instance name must match the legacy name so existing state is not replaced.
run "byo_project_default_database_name" {
  command = plan

  module {
    source = "./byo-project"
  }

  variables {
    project_id           = "my-existing-project"
    load_balancer_config = {}
  }

  assert {
    condition     = var.database_config.name == "fleet-mysql"
    error_message = "byo-project default Cloud SQL instance name must stay fleet-mysql to avoid replacement."
  }
}

# Regional HTTPS redirect needs the managed cert's HTTPS listener; the
# unsupported combination is rejected at the root and direct-child inputs.
run "root_regional_redirect_without_managed_cert_rejected" {
  command = plan

  variables {
    create_project = false
    project_id     = "my-existing-project"
    load_balancer_config = {
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = true
    }
  }

  expect_failures = [var.load_balancer_config]
}

run "root_regional_without_managed_cert_or_redirect_allowed" {
  command = plan

  variables {
    create_project = false
    project_id     = "my-existing-project"
    load_balancer_config = {
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = false
    }
  }

  assert {
    condition     = var.load_balancer_config.create_managed_cert == false && var.load_balancer_config.https_redirect == false
    error_message = "Regional LB without managed cert and without redirect must remain valid."
  }
}

run "root_lb_disabled_redirect_without_managed_cert_allowed" {
  command = plan

  variables {
    create_project = false
    project_id     = "my-existing-project"
    load_balancer_config = {
      enable              = false
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = true
    }
  }

  assert {
    condition     = var.load_balancer_config.enable == false
    error_message = "A disabled LB must accept any redirect/cert combination."
  }
}

run "byo_project_regional_redirect_without_managed_cert_rejected" {
  command = plan

  module {
    source = "./byo-project"
  }

  variables {
    project_id = "my-existing-project"
    load_balancer_config = {
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = true
    }
  }

  expect_failures = [var.load_balancer_config]
}
