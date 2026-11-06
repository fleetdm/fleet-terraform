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
    "networkconnectivity.googleapis.com"
  ]

  labels = var.labels
}

# -------------------------------------
# Google Calendar Integration
# -------------------------------------

resource "google_service_account" "fleet_calendar" {
  project      = module.project_factory.project_id
  account_id   = "fleet-calendar-events"
  display_name = "Fleet Calendar Events"
  description  = "Service account for Fleet to create calendar events for end users with failing policies"
}

resource "google_service_account_key" "fleet_calendar" {
  service_account_id = google_service_account.fleet_calendar.name
}

resource "google_secret_manager_secret" "fleet_calendar_key" {
  project   = module.project_factory.project_id
  secret_id = "fleet-calendar-service-account-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "fleet_calendar_key" {
  secret      = google_secret_manager_secret.fleet_calendar_key.name
  secret_data = base64decode(google_service_account_key.fleet_calendar.private_key)
}

output "fleet_calendar_service_account_key_json" {
  description = "Google Calendar service account key JSON — set this as FLEET_GOOGLE_CALENDAR_SERVICE_ACCOUNT_KEY in GitHub Actions secrets"
  value       = base64decode(google_service_account_key.fleet_calendar.private_key)
  sensitive   = true
}

module "fleet" {
  source          = "./byo-project"
  project_id      = module.project_factory.project_id
  dns_record_name = var.dns_record_name
  dns_zone_name   = var.dns_zone_name
  vpc_config      = var.vpc_config
  fleet_config    = var.fleet_config
  cache_config    = var.cache_config
  database_config = var.database_config
  region          = var.region
  location        = var.location
}
