terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.35.0"
    }

    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 1.0"
    }
  }
}

data "google_client_config" "current" {}
