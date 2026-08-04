terraform {
  required_version = "~> 1.11"

  # Configure your own remote state backend before apply.
  # backend "gcs" {
  #   bucket = "your-fleet-terraform-state"
  #   prefix = "prod/fleet-gcp"
  # }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  # Use project_factory output when creating project, otherwise use provided project_id
  effective_project_id = var.create_project ? module.project_factory[0].project_id : var.project_id
}

module "project_factory" {
  count   = var.create_project ? 1 : 0
  source  = "terraform-google-modules/project-factory/google"
  version = "~> 18.0.0"

  name              = var.project_name
  random_project_id = var.random_project_id
  org_id            = var.folder_id == null ? var.org_id : ""
  folder_id         = var.folder_id == null ? "" : var.folder_id
  billing_account   = var.billing_account_id

  default_service_account = "delete"

  # Enable baseline APIs needed by most projects + your app stack
  activate_apis = concat([
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
  ], var.extra_apis)

  labels = var.labels
}

module "fleet" {
  source = "./byo-project"

  project_id           = local.effective_project_id
  region               = var.region
  location             = var.location
  dns_zone_name        = var.dns_zone_name
  dns_record_name      = var.dns_record_name
  dns_config           = var.dns_config
  vpc_config           = var.vpc_config
  fleet_config         = var.fleet_config
  cache_config         = var.cache_config
  database_config      = var.database_config
  load_balancer_config = var.load_balancer_config
  cmek                 = var.cmek
  cloud_armor          = var.cloud_armor
  replicate_secrets    = var.replicate_secrets
  allow_destroy        = var.allow_destroy
}
