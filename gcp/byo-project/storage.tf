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

  versioning {
    enabled = true
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

resource "google_storage_bucket" "packages_mirror" {
  project       = var.project_id
  name          = "${var.project_id}-fleet-packages-mirror"
  location      = var.location
  force_destroy = var.allow_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  dynamic "encryption" {
    for_each = var.cmek.enable ? [1] : []
    content {
      default_kms_key_name = local.kms_crypto_key_id
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_cmek]
}

resource "google_storage_bucket_iam_member" "fleet_read_packages_mirror" {
  bucket = google_storage_bucket.packages_mirror.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}
