resource "random_pet" "suffix" {
  length = 1
}

# Replication mode for all fleet-managed secrets. Empty replicate_secrets =
# automatic (Google-chosen); non-empty = user_managed with one replica per
# region. Used via dynamic blocks in each google_secret_manager_secret.
locals {
  secret_use_user_managed_replication = length(var.replicate_secrets) > 0
}

resource "google_secret_manager_secret" "database_password" {
  project   = var.project_id
  secret_id = "fleet-db-password-${random_pet.suffix.id}"

  replication {
    dynamic "auto" {
      for_each = local.secret_use_user_managed_replication ? [] : [1]
      content {}
    }
    dynamic "user_managed" {
      for_each = local.secret_use_user_managed_replication ? [1] : []
      content {
        dynamic "replicas" {
          for_each = var.replicate_secrets
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "database_password" {
  secret      = google_secret_manager_secret.database_password.name
  secret_data = module.mysql.generated_user_password
}

# -------------------------------------
# Fleet server private key
# -------------------------------------
locals {
  use_external_private_key_secret = nonsensitive(
    var.fleet_config.fleet_server_private_key_secret != null
  )
}

resource "random_password" "private_key" {
  count       = local.use_external_private_key_secret ? 0 : 1
  length      = 32
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1

  lifecycle {
    ignore_changes = [
      length,
      special,
      min_upper,
      min_lower,
      min_numeric,
      min_special,
      override_special,
    ]
  }
}

resource "google_secret_manager_secret" "private_key" {
  count     = local.use_external_private_key_secret ? 0 : 1
  project   = var.project_id
  secret_id = "fleet-private-key-${random_pet.suffix.id}"

  replication {
    dynamic "auto" {
      for_each = local.secret_use_user_managed_replication ? [] : [1]
      content {}
    }
    dynamic "user_managed" {
      for_each = local.secret_use_user_managed_replication ? [1] : []
      content {
        dynamic "replicas" {
          for_each = var.replicate_secrets
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "private_key" {
  count  = local.use_external_private_key_secret ? 0 : 1
  secret = google_secret_manager_secret.private_key[0].name
  secret_data = coalesce(
    var.fleet_config.fleet_server_private_key,
    random_password.private_key[0].result,
  )
}

# When the user provides an existing secret, look it up so we can verify it
# exists at plan time and grant the Fleet SA read access.
data "google_secret_manager_secret" "external_private_key" {
  count     = local.use_external_private_key_secret ? 1 : 0
  project   = var.project_id
  secret_id = nonsensitive(var.fleet_config.fleet_server_private_key_secret)
}

locals {
  # Short secret_id (name) used by the Cloud Run secret env var.
  fleet_private_key_secret_name = local.use_external_private_key_secret ? (
    data.google_secret_manager_secret.external_private_key[0].secret_id
  ) : google_secret_manager_secret.private_key[0].secret_id

  # Full resource ID used for IAM bindings.
  fleet_private_key_secret_id = local.use_external_private_key_secret ? (
    data.google_secret_manager_secret.external_private_key[0].id
  ) : google_secret_manager_secret.private_key[0].id
}

resource "google_secret_manager_secret" "hmac_secret" {
  project   = var.project_id
  secret_id = "fleet-hmac-secret-${random_pet.suffix.id}"

  replication {
    dynamic "auto" {
      for_each = local.secret_use_user_managed_replication ? [] : [1]
      content {}
    }
    dynamic "user_managed" {
      for_each = local.secret_use_user_managed_replication ? [1] : []
      content {
        dynamic "replicas" {
          for_each = var.replicate_secrets
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "hmac_secret" {
  secret      = google_secret_manager_secret.hmac_secret.name
  secret_data = google_storage_hmac_key.key.secret
}