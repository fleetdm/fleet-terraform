// Mocked checks for how the optional Cloud Armor policy is attached to the
// regional backend service. Uses mock providers, so no GCP credentials are
// needed and nothing is created. Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Contract under test:
//   * attachment is the native google-beta security_policy argument on
//     google_compute_region_backend_service (no gcloud local-exec). The
//     stable google provider has no such argument, so these runs fail to
//     validate if the backend service loses `provider = google-beta`.
//   * Cloud Armor off (default) -> security_policy is null (nothing attached;
//     turning it off later detaches the policy)
//   * Cloud Armor on            -> security_policy is the regional policy ID
//   * enabling with both lists empty is still rejected
//
// Mock plans cannot prove apply-time ordering. The backend service waits for
// the policy and its allow/default-deny rules through its depends_on list,
// which is visible in `terraform graph`. Detach-before-delete when Cloud
// Armor is turned off comes from terraform_data.cloud_armor_detach_before_destroy
// (create_before_destroy forced onto the policy), visible in the apply graph.
//
// google-beta is only required by child registry modules and the regional
// backend service, so every run maps the mocks explicitly; otherwise the real
// google-beta provider is used.

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

// Make the policy ID known at plan time so the attachment can be compared.
override_resource {
  target          = google_compute_region_security_policy.regional_security_policy
  override_during = plan
  values = {
    id = "projects/fleet-test-project/regions/us-central1/securityPolicies/fleet-regional-security-policy"
  }
}

variables {
  project_id      = "fleet-test-project"
  dns_zone_name   = "example.com."
  dns_record_name = "fleet.example.com."
  load_balancer_config = {
    use_regional_lb = true
  }
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

run "armor_off_by_default_attaches_nothing" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = length(google_compute_region_backend_service.regional_backend) == 1
    error_message = "The regional load balancer must still create its backend service."
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == null
    error_message = "With Cloud Armor off (default) the regional backend service must have no security policy attached."
  }

  assert {
    condition     = length(google_compute_region_security_policy.regional_security_policy) == 0
    error_message = "With Cloud Armor off (default) no security policy may be created."
  }

  assert {
    condition     = length(terraform_data.cloud_armor_detach_before_destroy) == 0
    error_message = "With Cloud Armor off (default) no detach-ordering helper may be created."
  }
}

run "armor_on_ip_only_attaches_policy_natively" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    cloud_armor = {
      enable            = true
      allowed_ip_ranges = ["203.0.113.0/24"]
    }
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == google_compute_region_security_policy.regional_security_policy[0].id
    error_message = "With Cloud Armor on the regional backend service must attach the regional security policy by ID."
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == "projects/fleet-test-project/regions/us-central1/securityPolicies/fleet-regional-security-policy"
    error_message = "With Cloud Armor on the regional backend service must attach the regional security policy by ID."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips) == 1 && length(google_compute_region_security_policy_rule.default_deny) == 1
    error_message = "The attached policy must keep its IP allow rule and default deny rule."
  }
  // Forces create_before_destroy onto the policy so that turning Cloud Armor
  // off detaches the backend service before the policy is deleted.
  assert {
    condition     = length(terraform_data.cloud_armor_detach_before_destroy) == 1
    error_message = "With Cloud Armor on the detach-before-destroy ordering helper must track the policy."
  }

  assert {
    condition     = terraform_data.cloud_armor_detach_before_destroy[0].input == google_compute_region_security_policy.regional_security_policy[0].id
    error_message = "With Cloud Armor on the detach-before-destroy ordering helper must track the policy."
  }
}

run "armor_on_paths_only_attaches_policy_natively" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    cloud_armor = {
      enable             = true
      allow_public_paths = ["^/api/fleet/orbit/"]
    }
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == google_compute_region_security_policy.regional_security_policy[0].id
    error_message = "A paths-only policy must also be attached natively to the regional backend service."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_public_paths) == 1 && length(google_compute_region_security_policy_rule.default_deny) == 1
    error_message = "The attached policy must keep its public path rule and default deny rule."
  }
}

run "armor_on_with_both_lists_empty_is_still_rejected" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    cloud_armor = {
      enable = true
    }
  }

  expect_failures = [
    var.cloud_armor,
  ]
}
