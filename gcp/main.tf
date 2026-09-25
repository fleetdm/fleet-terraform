terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}

provider "google" {
  # Credentials used here need Org/Folder level permissions
  default_labels = var.labels
}


module "project_factory" {
  source  = "terraform-google-modules/project-factory/google"
  version = "~> 18.0.0"

  name              = var.project_name
  random_project_id = var.random_project_id
  org_id            = var.org_id
  billing_account   = var.billing_account_id

  default_service_account = "delete"

  # Enable baseline APIs needed by most projects + your app stack
  activate_apis = [
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
    "pubsub.googleapis.com",
    "bigquery.googleapis.com"
  ]

  labels = var.labels
}

module "fleet_pubsub" {
  source         = "../addons/gcp/fleet-pubsub"
  project_id     = module.project_factory.project_id
  fleet_sa_email = module.fleet.fleet_service_account_email
}

module "pubsub_to_bigquery" {
  count  = var.pubsub_to_bigquery_image != null ? 1 : 0
  source = "../addons/gcp/pubsub-to-bigquery"

  project_id        = module.project_factory.project_id
  region            = var.region
  image             = var.pubsub_to_bigquery_image
  result_topic_name = module.fleet_pubsub.result_topic_name
  status_topic_name = module.fleet_pubsub.status_topic_name
  audit_topic_name  = module.fleet_pubsub.audit_topic_name
}

module "fleet" {
  source          = "./byo-project"
  project_id      = module.project_factory.project_id
  dns_record_name = var.dns_record_name
  dns_zone_name   = var.dns_zone_name
  vpc_config      = var.vpc_config
  fleet_config    = merge(var.fleet_config, {
    extra_env_vars = merge(
      try(var.fleet_config.extra_env_vars, {}),
      module.fleet_pubsub.fleet_env_vars
    )
  })
  cache_config    = var.cache_config
  database_config = var.database_config
  region          = var.region
  location        = var.location
}
