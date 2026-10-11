# Test-only helper for tests/cmek_iam_propagation_delay.tftest.hcl
# (run "unknown_key_ids_are_plannable"). Calls byo-project with every
# per-service CMEK consumer opted in and key IDs that are unknown at plan time
# (derived from terraform_data.id), as when keys are created in the same
# apply. Never applied; all providers are mocked by the test file.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    google-beta = {
      source = "hashicorp/google-beta"
    }
    terracurl = {
      source = "devops-rob/terracurl"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

variable "project_id" {
  type = string
}

variable "dns_zone_name" {
  type = string
}

variable "dns_record_name" {
  type = string
}

variable "fleet_config" {
  type = any
}

resource "terraform_data" "unknown_key_suffix" {
  input = "fleet"
}

locals {
  # terraform_data.id is generated at apply, so these are unknown at plan.
  regional_key = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/k-${terraform_data.unknown_key_suffix.id}"
  east_key     = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/k-${terraform_data.unknown_key_suffix.id}"
}

module "fleet" {
  source = "../.."

  project_id        = var.project_id
  dns_zone_name     = var.dns_zone_name
  dns_record_name   = var.dns_record_name
  fleet_config      = var.fleet_config
  replicate_secrets = ["us-central1", "us-east1"]

  cmek = {
    cloud_sql = { kms_key_id = local.regional_key }
    redis     = { kms_key_id = local.regional_key }
    cloud_run = { kms_key_id = local.regional_key }
    secret_manager = {
      replica_kms_key_ids = {
        us-central1 = local.regional_key
        us-east1    = local.east_key
      }
    }
  }
}
