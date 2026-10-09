# No-cloud checks for the root-level cloud_armor input contract.
#
# Cloud Armor is an optional, operator-owned allowlist:
#   * off by default
#   * allowed_ip_ranges  -> those sources may reach any path
#   * allow_public_paths -> matching paths may be reached from any source
#   * everything else    -> 403
# IP-only and paths-only policies are valid. Enabling it with both lists empty
# is rejected at the root and at the direct-child (byo-project) inputs,
# because it would deny all traffic. No endpoints are added automatically.
#
# Every provider is mocked and module.fleet is overridden, so these runs never
# contact Google Cloud. Rule rendering (priorities, CEL escaping) is covered by
# byo-project/tests/cloud_armor.tftest.hcl. Run from the gcp/ directory:
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
  target = module.fleet
}

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

run "root_cloud_armor_off_by_default" {
  command = plan

  assert {
    condition     = var.cloud_armor.enable == false
    error_message = "cloud_armor must be disabled by default."
  }

  assert {
    condition     = length(var.cloud_armor.allowed_ip_ranges) == 0
    error_message = "cloud_armor must not default any allowed IP ranges."
  }

  assert {
    condition     = length(var.cloud_armor.allow_public_paths) == 0
    error_message = "cloud_armor must not default any public paths (no automatic endpoints)."
  }
}

run "root_cloud_armor_disabled_with_empty_lists_valid" {
  command = plan

  variables {
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable             = false
      allowed_ip_ranges  = []
      allow_public_paths = []
    }
  }

  assert {
    condition     = var.cloud_armor.enable == false
    error_message = "A disabled policy with empty lists must remain valid."
  }
}

run "root_cloud_armor_enabled_with_both_lists_empty_rejected" {
  command = plan

  variables {
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable = true
    }
  }

  expect_failures = [var.cloud_armor]
}

run "root_cloud_armor_ip_only_valid" {
  command = plan

  variables {
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable            = true
      allowed_ip_ranges = ["203.0.113.0/24"]
    }
  }

  assert {
    condition     = var.cloud_armor.allowed_ip_ranges == tolist(["203.0.113.0/24"])
    error_message = "An IP-only policy must be accepted unchanged."
  }

  assert {
    condition     = length(var.cloud_armor.allow_public_paths) == 0
    error_message = "An IP-only policy must not gain public paths automatically."
  }
}

run "root_cloud_armor_paths_only_valid" {
  command = plan

  variables {
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable             = true
      allow_public_paths = ["^/api/fleet/orbit/"]
    }
  }

  assert {
    condition     = var.cloud_armor.allow_public_paths == tolist(["^/api/fleet/orbit/"])
    error_message = "A paths-only policy must be accepted unchanged."
  }

  assert {
    condition     = length(var.cloud_armor.allowed_ip_ranges) == 0
    error_message = "A paths-only policy must not gain IP ranges automatically."
  }
}

run "root_cloud_armor_mixed_valid" {
  command = plan

  variables {
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable             = true
      allowed_ip_ranges  = ["203.0.113.0/24"]
      allow_public_paths = ["^/api/fleet/orbit/", "^/api/v\\d+/a\\.b$", "^/q\"uote'"]
    }
  }

  assert {
    condition     = var.cloud_armor.allow_public_paths == tolist(["^/api/fleet/orbit/", "^/api/v\\d+/a\\.b$", "^/q\"uote'"])
    error_message = "Public path regexes containing backslashes and quotes must be accepted unchanged."
  }
}

run "byo_project_cloud_armor_enabled_with_both_lists_empty_rejected" {
  command = plan

  module {
    source = "./byo-project"
  }

  variables {
    project_id = "my-existing-project"
    load_balancer_config = {
      use_regional_lb = true
    }
    cloud_armor = {
      enable             = true
      allowed_ip_ranges  = []
      allow_public_paths = []
    }
  }

  expect_failures = [var.cloud_armor]
}
