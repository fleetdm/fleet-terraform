# No-cloud checks that the root module exports the existing serverless NEG for
# bring-your-own load balancer mode (load_balancer_config.enable = false) and
# with the module-managed load balancer enabled. module.fleet is NOT
# overridden, so the root output is wired to the real child output. Detailed
# child checks (ingress, absent LB resources) live in
# byo-project/tests/byo_load_balancer.tftest.hcl.
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

# Make the child NEG ID known at plan time so the root output can be compared.
override_resource {
  target          = module.fleet.google_compute_region_network_endpoint_group.neg
  override_during = plan
  values = {
    id = "projects/fleet-existing-1234/regions/us-central1/networkEndpointGroups/fleet-neg"
  }
}

variables {
  create_project  = false
  project_id      = "fleet-existing-1234"
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

run "root_byo_lb_exports_neg_and_null_lb_outputs" {
  command = plan

  variables {
    load_balancer_config = {
      enable = false
    }
  }

  assert {
    condition     = output.serverless_neg_id == "projects/fleet-existing-1234/regions/us-central1/networkEndpointGroups/fleet-neg"
    error_message = "Root serverless_neg_id must expose the existing child NEG when the module-managed load balancer is disabled."
  }

  assert {
    condition = (
      output.fleet_application_url == null &&
      output.load_balancer_ip_address == null &&
      output.load_balancer_type == "none"
    )
    error_message = "With the module-managed load balancer disabled, root URL/IP outputs must be null and load_balancer_type must be \"none\"."
  }
}

run "root_managed_lb_exports_same_neg" {
  command = plan

  assert {
    condition     = output.serverless_neg_id == "projects/fleet-existing-1234/regions/us-central1/networkEndpointGroups/fleet-neg"
    error_message = "Root serverless_neg_id must be the same existing NEG when the module-managed load balancer is enabled."
  }

  assert {
    condition     = output.load_balancer_type == "global"
    error_message = "Default root configuration must keep the module-managed global load balancer."
  }
}
