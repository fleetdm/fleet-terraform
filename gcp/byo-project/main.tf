terraform {
  required_version = "~> 1.12"
  required_providers {
    # Stays on 6.x: the cloud-router (7.0) and memorystore (14.x) modules
    # require google < 7.
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0, < 7.0.0"
    }

    # Needed directly for google_project_service_identity (CMEK service agents)
    # and the Cloud Run resources in modules/fleet-lifecycle. 7.x is required
    # by the upstream lb-http, sql-db, network and project-factory versions
    # used here, which all accept google-beta < 8.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.24.0, < 8.0.0"
    }

    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 1.0"
    }

    # time_sleep for the per-service CMEK IAM propagation wait
    # (cmek-readiness.tf). 0.9.0+ is the plugin-framework rewrite.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

data "google_client_config" "current" {}
