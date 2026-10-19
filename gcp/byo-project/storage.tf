resource "google_storage_hmac_key" "key" {
  project               = var.project_id
  service_account_email = google_service_account.fleet_run_sa.email
}

resource "google_storage_bucket" "software_installers" {
  project       = var.project_id
  name          = nonsensitive(var.fleet_config.installers_bucket_name)
  location      = var.location
  force_destroy = var.allow_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Versioning and noncurrent-version expiry come from
  # software_installers_config (storage-config.tf); both default to the AWS
  # module behavior: versioning off, and when on, 30-day noncurrent expiry.
  versioning {
    enabled = var.software_installers_config.enable_bucket_versioning
  }

  # Deletes only noncurrent (ARCHIVED) versions; live objects never match.
  dynamic "lifecycle_rule" {
    for_each = local.software_installers_expire_noncurrent ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        days_since_noncurrent_time = var.software_installers_config.noncurrent_version_expiration_days
        with_state                 = "ARCHIVED"
      }
    }
  }

  # Optional CMEK encryption. The IAM binding granting the GCS service agent
  # access to the KMS key is created in kms.tf.
  dynamic "encryption" {
    for_each = var.cmek.enable ? [1] : []
    content {
      default_kms_key_name = local.kms_crypto_key_id
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_cmek]
}

resource "google_storage_bucket_iam_member" "hmac_sa_storage_admin" {
  bucket = google_storage_bucket.software_installers.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# The unused packages mirror existed only in an earlier draft, not on main.
# Stop creating it; forget any draft deployment's ownership without deleting
# a bucket or grant that an operator may have started using outside Fleet.
removed {
  from = google_storage_bucket.packages_mirror

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_storage_bucket_iam_member.fleet_read_packages_mirror

  lifecycle {
    destroy = false
  }
}
