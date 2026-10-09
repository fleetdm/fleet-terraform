// Plan-only checks for the optional Cloud Armor allowlist on the regional
// load balancer. Uses mock providers, so no GCP credentials are needed and
// nothing is created.
// Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Contract under test:
//   * off by default; nothing is created
//   * allowed_ip_ranges  -> those sources may reach any path
//   * allow_public_paths -> matching paths may be reached from any source
//   * everything else    -> deny(403) at priority 2147483647
//   * IP-only and paths-only policies are valid
//   * enable = true with both lists empty is rejected
//   * public path regexes are embedded as escaped CEL string literals
//
// google-beta is required by child registry modules and the regional backend
// service (native security_policy attachment), so every run maps the mocks
// explicitly; otherwise the real google-beta provider is used.

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

// Make the policy ID known at plan time so the native attachment
// (security_policy on the regional backend service) can be compared.
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

run "disabled_by_default" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = var.cloud_armor.enable == false
    error_message = "Cloud Armor must be off by default."
  }

  assert {
    condition     = length(google_compute_region_security_policy.regional_security_policy) == 0
    error_message = "Default (disabled) Cloud Armor must not create any policy, rule, or attachment."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_public_paths) == 0
    error_message = "Default (disabled) Cloud Armor must not create any policy, rule, or attachment."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips) == 0
    error_message = "Default (disabled) Cloud Armor must not create any policy, rule, or attachment."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.default_deny) == 0
    error_message = "Default (disabled) Cloud Armor must not create any policy, rule, or attachment."
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == null
    error_message = "Default (disabled) Cloud Armor must not create any policy, rule, or attachment."
  }
}

run "disabled_with_empty_lists_is_valid" {
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
      enable             = false
      allowed_ip_ranges  = []
      allow_public_paths = []
    }
  }

  assert {
    condition     = length(google_compute_region_security_policy.regional_security_policy) == 0
    error_message = "Explicitly disabled Cloud Armor must not create a policy."
  }
}

run "enabled_with_both_lists_empty_is_rejected" {
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

run "ip_only_policy_is_valid" {
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
      allowed_ip_ranges = ["203.0.113.0/24", "198.51.100.7/32"]
    }
  }

  assert {
    condition     = length(google_compute_region_security_policy.regional_security_policy) == 1
    error_message = "An IP-only policy must create the security policy."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_public_paths) == 0
    error_message = "An IP-only policy must not add any public path rules (no automatic endpoints)."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips) == 1
    error_message = "allowed_ip_ranges must become a single allow rule at priority 2000 with exactly the configured ranges."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["0"].action == "allow"
    error_message = "allowed_ip_ranges must become a single allow rule at priority 2000 with exactly the configured ranges."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["0"].priority == 2000
    error_message = "allowed_ip_ranges must become a single allow rule at priority 2000 with exactly the configured ranges."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["0"].match[0].config[0].src_ip_ranges == tolist(["203.0.113.0/24", "198.51.100.7/32"])
    error_message = "allowed_ip_ranges must become a single allow rule at priority 2000 with exactly the configured ranges."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.default_deny) == 1
    error_message = "All other traffic must be denied with 403 by the default rule at priority 2147483647."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.default_deny[0].priority == 2147483647
    error_message = "All other traffic must be denied with 403 by the default rule at priority 2147483647."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.default_deny[0].action == "deny(403)"
    error_message = "All other traffic must be denied with 403 by the default rule at priority 2147483647."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.default_deny[0].match[0].config[0].src_ip_ranges == tolist(["*"])
    error_message = "All other traffic must be denied with 403 by the default rule at priority 2147483647."
  }

  assert {
    condition     = google_compute_region_backend_service.regional_backend[0].security_policy == google_compute_region_security_policy.regional_security_policy[0].id
    error_message = "An enabled policy must be attached to the regional backend service."
  }
}

run "paths_only_policy_is_valid" {
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
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips) == 0
    error_message = "A paths-only policy must not add any source IP allow rules."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_public_paths) == 1
    error_message = "allow_public_paths must become an allow rule at priority 1000 matching exactly the configured regex."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[0].action == "allow"
    error_message = "allow_public_paths must become an allow rule at priority 1000 matching exactly the configured regex."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[0].priority == 1000
    error_message = "allow_public_paths must become an allow rule at priority 1000 matching exactly the configured regex."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[0].match[0].expr[0].expression == "request.path.matches(\"^/api/fleet/orbit/\")"
    error_message = "allow_public_paths must become an allow rule at priority 1000 matching exactly the configured regex."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.default_deny[0].action == "deny(403)"
    error_message = "A paths-only policy must still deny all other traffic with 403."
  }
}

run "mixed_policy_is_valid_and_chunked" {
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
      allowed_ip_ranges = [
        "10.0.0.1/32", "10.0.0.2/32", "10.0.0.3/32", "10.0.0.4/32", "10.0.0.5/32",
        "10.0.0.6/32", "10.0.0.7/32", "10.0.0.8/32", "10.0.0.9/32", "10.0.0.10/32",
        "10.0.0.11/32",
      ]
      allow_public_paths = ["^/p1/", "^/p2/", "^/p3/", "^/p4/", "^/p5/", "^/p6/"]
    }
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips) == 2
    error_message = "11 IP ranges must be split into rules of at most 10 ranges at priorities 2000 and 2010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["0"].priority == 2000
    error_message = "11 IP ranges must be split into rules of at most 10 ranges at priorities 2000 and 2010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["1"].priority == 2010
    error_message = "11 IP ranges must be split into rules of at most 10 ranges at priorities 2000 and 2010."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_admin_ips["0"].match[0].config[0].src_ip_ranges) == 10
    error_message = "11 IP ranges must be split into rules of at most 10 ranges at priorities 2000 and 2010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_admin_ips["1"].match[0].config[0].src_ip_ranges == tolist(["10.0.0.11/32"])
    error_message = "11 IP ranges must be split into rules of at most 10 ranges at priorities 2000 and 2010."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.allow_public_paths) == 2
    error_message = "6 public paths must be split into rules of at most 5 CEL sub-expressions at priorities 1000 and 1010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[0].priority == 1000
    error_message = "6 public paths must be split into rules of at most 5 CEL sub-expressions at priorities 1000 and 1010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[1].priority == 1010
    error_message = "6 public paths must be split into rules of at most 5 CEL sub-expressions at priorities 1000 and 1010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[0].match[0].expr[0].expression == "request.path.matches(\"^/p1/\") || request.path.matches(\"^/p2/\") || request.path.matches(\"^/p3/\") || request.path.matches(\"^/p4/\") || request.path.matches(\"^/p5/\")"
    error_message = "6 public paths must be split into rules of at most 5 CEL sub-expressions at priorities 1000 and 1010."
  }

  assert {
    condition     = google_compute_region_security_policy_rule.allow_public_paths[1].match[0].expr[0].expression == "request.path.matches(\"^/p6/\")"
    error_message = "6 public paths must be split into rules of at most 5 CEL sub-expressions at priorities 1000 and 1010."
  }

  assert {
    condition     = length(google_compute_region_security_policy_rule.default_deny) == 1
    error_message = "A mixed policy must keep the default deny rule."
  }
}

// Regression: patterns used to be interpolated raw into a single-quoted CEL
// literal, so a quote could close the literal and inject CEL, and backslashes
// were reinterpreted by CEL. Each pattern must now be a double-quoted CEL
// literal whose JSON/CEL escaping decodes back to the exact configured regex.
run "public_path_patterns_are_escaped_for_cel" {
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
      allow_public_paths = [
        // ordinary pattern
        "^/api/v1/fleet/device/",
        // backslash escapes in the regex: ^/api/v\d+/a\.b$
        "^/api/v\\d+/a\\.b$",
        // single-quote breakout attempt from the old '...' literal
        "^/x') || true || request.path.matches('y",
        // double-quote breakout attempt against the new "..." literal
        "^/x\") || true || request.path.matches(\"y",
        // trailing backslash that would otherwise escape the closing quote
        "^/trailing\\",
      ]
    }
  }

  // Exact rendered CEL, written with HCL escapes:
  //   \"  -> literal "     \\  -> literal \
  assert {
    condition = google_compute_region_security_policy_rule.allow_public_paths[0].match[0].expr[0].expression == join(" || ", [
      "request.path.matches(\"^/api/v1/fleet/device/\")",
      "request.path.matches(\"^/api/v\\\\d+/a\\\\.b$\")",
      "request.path.matches(\"^/x') || true || request.path.matches('y\")",
      "request.path.matches(\"^/x\\\") || true || request.path.matches(\\\"y\")",
      "request.path.matches(\"^/trailing\\\\\")",
    ])
    error_message = "Public path patterns must be rendered as escaped double-quoted CEL string literals."
  }

  // Tokenize the expression the way a CEL lexer reads double-quoted string
  // literals (a quote, then non-quote/non-backslash chars or backslash
  // escapes, then a closing quote). There must be exactly one literal per
  // configured pattern, and decoding each must give back exactly the
  // configured regex, in order: no breakout, intended regex content preserved.
  assert {
    condition = [
      for lit in regexall("\"(?:[^\"\\\\]|\\\\.)*\"", google_compute_region_security_policy_rule.allow_public_paths[0].match[0].expr[0].expression) : jsondecode(lit)
      ] == [
      "^/api/v1/fleet/device/",
      "^/api/v\\d+/a\\.b$",
      "^/x') || true || request.path.matches('y",
      "^/x\") || true || request.path.matches(\"y",
      "^/trailing\\",
    ]
    error_message = "Decoding the CEL literals must return the configured regexes unchanged."
  }
}
