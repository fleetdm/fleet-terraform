terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "6.32.0"
    }
  }
}

data "google_client_config" "current" {}
