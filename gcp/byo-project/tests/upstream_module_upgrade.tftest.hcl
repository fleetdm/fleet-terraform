// Upgrade guard for the terraform-google-modules/network VPC (11.0.0 -> 12.0.0).
// Every provider is mocked; nothing contacts Google Cloud.
//
// 12.0.0 adds bgp_always_compare_med, bgp_best_path_selection_mode and
// bgp_inter_region_cost to google_compute_network with non-null defaults.
// 11.0.0 did not set them, and the Compute API rejects bgp_always_compare_med
// together with LEGACY path selection. vpc.tf passes null for all three, so
// the network is configured exactly as with 11.0.0.
//
// A configured value always wins over a mock default, so the network gets the
// mock defaults below (applied at plan time) only for attributes the
// configuration leaves unset. Each assertion fails if the module sends that
// field.

mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b", "us-central1-c"]
    }
  }
}
mock_provider "google-beta" {
  mock_resource "google_compute_network" {
    override_during = plan
    defaults = {
      # Realistic identifiers: the Cloud SQL private_network validation reads
      # the network self link at plan time.
      id                           = "projects/fleet-test-project/global/networks/fleet-network"
      self_link                    = "https://www.googleapis.com/compute/v1/projects/fleet-test-project/global/networks/fleet-network"
      bgp_always_compare_med       = true
      bgp_best_path_selection_mode = "unset-in-configuration"
      bgp_inter_region_cost        = "unset-in-configuration"
    }
  }
}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "terracurl" {}
mock_provider "time" {}

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

run "vpc_network_routing_config_unchanged" {
  command = plan

  assert {
    condition     = module.vpc.network.network.bgp_always_compare_med == true
    error_message = "bgp_always_compare_med must stay unset (the API rejects it with LEGACY best path selection)."
  }

  assert {
    condition     = module.vpc.network.network.bgp_best_path_selection_mode == "unset-in-configuration"
    error_message = "bgp_best_path_selection_mode must stay unset, as with network module 11.0.0."
  }

  assert {
    condition     = module.vpc.network.network.bgp_inter_region_cost == "unset-in-configuration"
    error_message = "bgp_inter_region_cost must stay unset, as with network module 11.0.0."
  }

  assert {
    condition     = module.vpc.network_name == "fleet-network" && module.vpc.network.network.routing_mode == "GLOBAL"
    error_message = "Network name and routing mode must be unchanged by the module upgrade."
  }
}
