// Plan-only checks for bring-your-own load balancer mode
// (load_balancer_config.enable = false). The existing serverless NEG must be
// exported whether or not the module-managed load balancer is enabled, the
// load balancer outputs must report "no module-managed LB", and Cloud Run
// ingress must stay restricted to load balancer traffic.
//
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

// Make the NEG ID known at plan time so the output can be compared.
override_resource {
  target          = google_compute_region_network_endpoint_group.neg
  override_during = plan
  values = {
    id = "projects/fleet-test-project/regions/us-central1/networkEndpointGroups/fleet-neg"
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
}

run "byo_lb_exports_neg_and_null_lb_outputs" {
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
      enable = false
    }
  }

  assert {
    condition     = output.serverless_neg_id == "projects/fleet-test-project/regions/us-central1/networkEndpointGroups/fleet-neg"
    error_message = "serverless_neg_id must expose the existing serverless NEG when the module-managed load balancer is disabled."
  }

  assert {
    condition = (
      google_compute_region_network_endpoint_group.neg.network_endpoint_type == "SERVERLESS" &&
      google_compute_region_network_endpoint_group.neg.region == "us-central1" &&
      google_compute_region_network_endpoint_group.neg.cloud_run[0].service == "fleet-api"
    )
    error_message = "The exported NEG must be the regional serverless NEG for the Fleet Cloud Run service."
  }

  assert {
    condition = (
      output.fleet_application_url == null &&
      output.load_balancer_ip_address == null &&
      output.load_balancer_type == "none" &&
      output.regional_cert_dns_authorization_record == null
    )
    error_message = "With the module-managed load balancer disabled, URL/IP/cert outputs must be null and load_balancer_type must be \"none\"."
  }

  assert {
    condition = (
      length(module.fleet_lb) == 0 &&
      length(google_compute_region_network_endpoint_group.regional_neg) == 0 &&
      length(google_compute_region_backend_service.regional_backend) == 0 &&
      length(google_compute_forwarding_rule.regional_main) == 0 &&
      length(google_dns_record_set.fleet_dns_record) == 0
    )
    error_message = "BYO load balancer mode must not create any module-managed load balancer or DNS A record."
  }

  // The Cloud Run module does not output ingress, so guard the source setting.
  assert {
    condition     = can(regex("ingress\\s*=\\s*\"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER\"", file("${path.module}/cloud_run.tf")))
    error_message = "Cloud Run ingress must stay INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER; BYO load balancer mode must not open a public Cloud Run endpoint."
  }
}

run "global_lb_still_exports_same_neg" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition     = output.serverless_neg_id == "projects/fleet-test-project/regions/us-central1/networkEndpointGroups/fleet-neg"
    error_message = "serverless_neg_id must be the same existing NEG when the module-managed global load balancer is enabled."
  }

  assert {
    condition     = output.load_balancer_type == "global" && length(module.fleet_lb) == 1
    error_message = "Default configuration must keep the module-managed global load balancer."
  }
}

run "regional_lb_still_exports_same_neg" {
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
    }
  }

  assert {
    condition     = output.serverless_neg_id == "projects/fleet-test-project/regions/us-central1/networkEndpointGroups/fleet-neg"
    error_message = "serverless_neg_id must be the same existing NEG when the module-managed regional load balancer is enabled."
  }

  assert {
    condition     = output.load_balancer_type == "regional"
    error_message = "use_regional_lb = true must keep the module-managed regional load balancer."
  }
}
