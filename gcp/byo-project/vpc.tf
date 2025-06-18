# Example from your vpc.tf (ensure this part is correct)


locals {
  network_name = "${var.prefix}-network"
  subnet_name  = "${var.prefix}-subnet"
}


module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "11.0.0"

  project_id   = var.project_id
  network_name = var.vpc_config.network_name
  subnets      = var.vpc_config.subnets
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
