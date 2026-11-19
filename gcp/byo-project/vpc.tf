locals {
  network_name = "${var.prefix}-network"
  subnet_name  = "${var.prefix}-subnet"
}


module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "12.0.0"

  project_id   = var.project_id
  network_name = var.vpc_config.network_name
  subnets      = var.vpc_config.subnets

  # 12.0.0 sends these routing settings on google_compute_network by default
  # (bgp_always_compare_med = false, bgp_best_path_selection_mode = "LEGACY").
  # The Compute API rejects bgp_always_compare_med with LEGACY path selection,
  # so creating a network with those defaults fails. null leaves all three
  # unset, exactly as 11.0.0 did: new networks get the API defaults and
  # existing networks plan no routing change.
  bgp_always_compare_med       = null
  bgp_best_path_selection_mode = null
  bgp_inter_region_cost        = null
}

module "cloud_router" {
  source  = "terraform-google-modules/cloud-router/google"
  version = "7.0"
  name    = "${var.prefix}-cloud-router"
  project = var.project_id
  network = module.vpc.network_name
  region  = var.region

  nats = [{
    name = "${var.prefix}-vpc-nat"
  }]
}
