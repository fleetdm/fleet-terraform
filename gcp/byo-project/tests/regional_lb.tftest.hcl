// Plan-only checks for the regional external Application Load Balancer.
// Uses mock providers, so no GCP credentials are needed and nothing is
// created. Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
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

// Computed values the assertions compare, made known at plan time.
override_resource {
  target          = google_compute_address.regional_ip
  override_during = plan
  values = {
    id      = "projects/fleet-test-project/regions/us-central1/addresses/fleet-regional-ip"
    address = "203.0.113.10"
  }
}

override_resource {
  target          = google_compute_region_url_map.regional_url_map
  override_during = plan
  values = {
    id = "projects/fleet-test-project/regions/us-central1/urlMaps/fleet-regional-url-map"
  }
}

override_resource {
  target          = google_compute_region_url_map.regional_https_redirect
  override_during = plan
  values = {
    id = "projects/fleet-test-project/regions/us-central1/urlMaps/fleet-regional-https-redirect"
  }
}

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
  load_balancer_config = {
    use_regional_lb = true
  }
}

run "redirect_enabled_by_default" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = length(google_compute_region_url_map.regional_https_redirect) == 1
    error_message = "https_redirect (default true) must create the regional redirect URL map."
  }

  assert {
    condition = (
      google_compute_region_url_map.regional_https_redirect[0].default_url_redirect[0].https_redirect == true &&
      google_compute_region_url_map.regional_https_redirect[0].default_url_redirect[0].strip_query == false &&
      google_compute_region_url_map.regional_https_redirect[0].default_url_redirect[0].redirect_response_code == "MOVED_PERMANENTLY_DEFAULT"
    )
    error_message = "Regional redirect must be a 301 to HTTPS that preserves the query string."
  }

  assert {
    condition     = google_compute_region_target_http_proxy.regional_main_proxy[0].url_map == google_compute_region_url_map.regional_https_redirect[0].id
    error_message = "Port 80 proxy must use the redirect URL map when https_redirect is true."
  }

  assert {
    condition     = google_compute_region_target_https_proxy.regional_https_proxy[0].url_map == google_compute_region_url_map.regional_url_map[0].id
    error_message = "Port 443 proxy must keep serving from the backend URL map."
  }
}

run "redirect_disabled_serves_http" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb = true
      https_redirect  = false
    }
  }

  assert {
    condition     = length(google_compute_region_url_map.regional_https_redirect) == 0
    error_message = "https_redirect = false must not create the regional redirect URL map."
  }

  assert {
    condition     = google_compute_region_target_http_proxy.regional_main_proxy[0].url_map == google_compute_region_url_map.regional_url_map[0].id
    error_message = "Port 80 proxy must serve the backend URL map when https_redirect is false."
  }
}

run "shared_address_without_create_static_ip" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = length(google_compute_address.regional_ip) == 1
    error_message = "The regional LB must reserve exactly one address even when create_static_ip is false (default)."
  }

  assert {
    condition = (
      google_compute_forwarding_rule.regional_main[0].ip_address == google_compute_address.regional_ip[0].address &&
      google_compute_forwarding_rule.regional_https[0].ip_address == google_compute_address.regional_ip[0].address
    )
    error_message = "HTTP and HTTPS forwarding rules must share the reserved regional address."
  }

  assert {
    condition     = google_dns_record_set.fleet_dns_record[0].rrdatas == tolist([google_compute_address.regional_ip[0].address])
    error_message = "DNS A record must point at the shared regional address."
  }

  assert {
    condition     = output.load_balancer_ip_address == google_compute_address.regional_ip[0].address
    error_message = "load_balancer_ip_address output must report the shared regional address."
  }
}

run "shared_address_with_create_static_ip" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb  = true
      create_static_ip = true
    }
  }

  assert {
    condition = (
      length(google_compute_address.regional_ip) == 1 &&
      google_compute_forwarding_rule.regional_main[0].ip_address == google_compute_address.regional_ip[0].address &&
      google_compute_forwarding_rule.regional_https[0].ip_address == google_compute_address.regional_ip[0].address
    )
    error_message = "create_static_ip = true must keep the single shared regional address."
  }
}

run "regional_disabled_creates_no_regional_resources" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb = false
    }
  }

  assert {
    condition = (
      length(google_compute_address.regional_ip) == 0 &&
      length(google_compute_region_url_map.regional_url_map) == 0 &&
      length(google_compute_region_url_map.regional_https_redirect) == 0 &&
      length(google_compute_region_target_http_proxy.regional_main_proxy) == 0 &&
      length(google_compute_region_target_https_proxy.regional_https_proxy) == 0 &&
      length(google_compute_forwarding_rule.regional_main) == 0 &&
      length(google_compute_forwarding_rule.regional_https) == 0 &&
      length(google_compute_subnetwork.proxy_only) == 0
    )
    error_message = "use_regional_lb = false must not create any regional LB resources."
  }
}

run "lb_disabled_creates_no_regional_resources" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  // dns_config is left at its default (enable = true): with the LB disabled
  // there is no record to publish, so the URL output must not index it.
  variables {
    load_balancer_config = {
      enable          = false
      use_regional_lb = true
    }
  }

  assert {
    condition = (
      length(google_compute_address.regional_ip) == 0 &&
      length(google_compute_region_url_map.regional_https_redirect) == 0 &&
      length(google_compute_forwarding_rule.regional_main) == 0 &&
      length(google_compute_forwarding_rule.regional_https) == 0
    )
    error_message = "load_balancer_config.enable = false must not create regional LB resources."
  }

  assert {
    condition     = var.dns_config.enable == true
    error_message = "This run must exercise the default dns_config.enable = true."
  }

  assert {
    condition     = length(google_dns_record_set.fleet_dns_record) == 0
    error_message = "load_balancer_config.enable = false must not create the Fleet DNS A record."
  }

  assert {
    condition     = output.fleet_application_url == null
    error_message = "fleet_application_url must be null when the load balancer is disabled."
  }
}

run "regional_redirect_without_managed_cert_rejected" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = true
    }
  }

  expect_failures = [var.load_balancer_config]
}

run "regional_without_managed_cert_or_redirect_serves_http" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = false
    }
  }

  assert {
    condition = (
      length(google_compute_region_url_map.regional_https_redirect) == 0 &&
      length(google_compute_region_target_https_proxy.regional_https_proxy) == 0 &&
      length(google_compute_forwarding_rule.regional_https) == 0 &&
      length(google_certificate_manager_certificate.regional_cert) == 0
    )
    error_message = "create_managed_cert = false with https_redirect = false must not create a redirect, HTTPS listener or certificate."
  }

  assert {
    condition     = google_compute_region_target_http_proxy.regional_main_proxy[0].url_map == google_compute_region_url_map.regional_url_map[0].id
    error_message = "Port 80 proxy must serve the backend URL map when there is no HTTPS listener."
  }

  assert {
    condition     = output.regional_cert_dns_authorization_record == null
    error_message = "No certificate DNS authorization record should be reported without a managed cert."
  }
}

run "lb_disabled_allows_redirect_without_managed_cert" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      enable              = false
      use_regional_lb     = true
      create_managed_cert = false
      https_redirect      = true
    }
  }

  assert {
    condition = (
      output.load_balancer_type == "none" &&
      output.fleet_application_url == null &&
      length(google_compute_region_url_map.regional_https_redirect) == 0
    )
    error_message = "A disabled LB must accept any redirect/cert combination and create no LB resources."
  }
}

run "global_allows_redirect_without_managed_cert" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {
      use_regional_lb     = false
      create_managed_cert = false
      https_redirect      = true
    }
  }

  assert {
    condition     = output.load_balancer_type == "global"
    error_message = "The regional-only validation must not affect the global LB path."
  }
}

run "default_lb_config_unchanged" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    load_balancer_config = {}
  }

  assert {
    condition = (
      var.load_balancer_config.enable == true &&
      var.load_balancer_config.use_regional_lb == false &&
      var.load_balancer_config.https_redirect == true &&
      var.load_balancer_config.create_managed_cert == true
    )
    error_message = "Default load_balancer_config values changed unexpectedly."
  }

  assert {
    condition = (
      output.load_balancer_type == "global" &&
      length(google_dns_record_set.fleet_dns_record) == 1 &&
      output.fleet_application_url == "https://fleet.example.com."
    )
    error_message = "Default config must plan the global LB with a DNS record and application URL."
  }
}

run "canonical_invoker_binding_owned_by_cloud_run" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition = (
      google_cloud_run_v2_service_iam_member.allow_lb_invoker.role == "roles/run.invoker" &&
      google_cloud_run_v2_service_iam_member.allow_lb_invoker.member == "allUsers"
    )
    error_message = "cloud_run.tf allow_lb_invoker must keep owning the run.invoker/allUsers binding for the regional LB."
  }
}
