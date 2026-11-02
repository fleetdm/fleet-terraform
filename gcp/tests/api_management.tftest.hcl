# No-cloud checks for opt-in API management on existing projects
# (manage_existing_project_apis).
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

  # Exact baseline the project factory enabled before this feature existed.
  expected_baseline_apis = [
    "compute.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "run.googleapis.com",
    "vpcaccess.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "memorystore.googleapis.com",
    "serviceconsumermanagement.googleapis.com",
    "networkconnectivity.googleapis.com",
    "certificatemanager.googleapis.com",
  ]
}

# Default BYO behavior: API enablement stays manual; the root manages nothing.
run "existing_project_default_manages_no_apis" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    create_project = false
    project_id     = "my-existing-project"
    extra_apis     = ["cloudkms.googleapis.com"]
  }

  assert {
    condition     = var.manage_existing_project_apis == false
    error_message = "manage_existing_project_apis must default to false."
  }

  assert {
    condition     = length(google_project_service.existing_project_apis) == 0
    error_message = "Existing projects must not manage APIs unless manage_existing_project_apis = true."
  }

  assert {
    condition     = length(module.project_factory) == 0
    error_message = "create_project=false must not create a project."
  }
}

# Opt-in BYO: baseline plus extra_apis, deduplicated, never disabled on destroy.
run "existing_project_opt_in_manages_baseline_and_extras" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    create_project               = false
    project_id                   = "my-existing-project"
    manage_existing_project_apis = true
    extra_apis = [
      "compute.googleapis.com",  # duplicate of a baseline API
      "cloudkms.googleapis.com", # genuinely extra
      "cloudkms.googleapis.com", # duplicate extra
    ]
  }

  assert {
    condition     = local.baseline_project_apis == var.expected_baseline_apis
    error_message = "Baseline API list changed unexpectedly."
  }

  assert {
    condition = (
      toset(keys(google_project_service.existing_project_apis)) ==
      toset(concat(var.expected_baseline_apis, ["cloudkms.googleapis.com"]))
    )
    error_message = "Opted-in existing projects must manage exactly the baseline APIs plus extra_apis."
  }

  assert {
    condition     = length(google_project_service.existing_project_apis) == length(var.expected_baseline_apis) + 1
    error_message = "Duplicate APIs between the baseline and extra_apis must collapse to one resource each."
  }

  assert {
    condition     = alltrue([for s in google_project_service.existing_project_apis : s.disable_on_destroy == false])
    error_message = "Managed APIs must never be disabled on destroy."
  }

  assert {
    condition     = alltrue([for s in google_project_service.existing_project_apis : s.disable_dependent_services == false])
    error_message = "Managed APIs must never disable dependent services."
  }

  assert {
    condition     = alltrue([for k, s in google_project_service.existing_project_apis : s.project == "my-existing-project" && s.service == k])
    error_message = "Managed APIs must target var.project_id explicitly."
  }

  assert {
    condition     = length(module.project_factory) == 0
    error_message = "create_project=false must not create a project."
  }
}

# The flag has no effect for new projects: the factory owns API enablement and
# its activate_apis list is unchanged.
run "new_project_ignores_opt_in_flag" {
  command = plan

  override_module {
    target = module.fleet
  }

  variables {
    org_id                       = "123456789012"
    billing_account_id           = "AAAAAA-BBBBBB-CCCCCC"
    manage_existing_project_apis = true
    extra_apis                   = ["cloudkms.googleapis.com"]
  }

  assert {
    condition     = length(google_project_service.existing_project_apis) == 0
    error_message = "create_project=true must not manage APIs through the existing-project resources."
  }

  assert {
    condition     = length(module.project_factory) == 1
    error_message = "create_project=true must still create the project via project_factory."
  }

  assert {
    condition = (
      toset(module.project_factory[0].enabled_apis) ==
      toset(concat(var.expected_baseline_apis, ["cloudkms.googleapis.com"]))
    )
    error_message = "project_factory enabled APIs must remain the baseline plus extra_apis."
  }
}

# Plan the real child module with the flag enabled to prove module.fleet still
# plans when it depends on the opted-in API resources.
run "existing_project_opt_in_plans_full_stack" {
  command = plan

  variables {
    create_project               = false
    project_id                   = "my-existing-project"
    manage_existing_project_apis = true
  }

  assert {
    condition     = length(google_project_service.existing_project_apis) == length(var.expected_baseline_apis)
    error_message = "Opted-in existing projects must manage the baseline APIs."
  }
}
