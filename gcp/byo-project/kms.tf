# -------------------------------------
# Cloud KMS for CMEK (Customer-Managed Encryption Keys)
# -------------------------------------
# Two modes, gated by cmek.create_kms:
#   - create_kms = false (default): key ring and crypto key must already exist in
#     the project at the region. Terraform only references them.
#   - create_kms = true: Terraform creates the key ring and crypto key in this
#     project/region using the provided names.
#
# The resolved crypto key path is exported via local.kms_crypto_key_id so any
# resource that supports CMEK (GCS buckets today; Cloud SQL, Memorystore, etc.
# in the future) can reference it.
#
# WARNING: key rings and crypto keys cannot be truly deleted in GCP. On
# `terraform destroy`, key versions are scheduled for destruction (default 24h)
# and the resources leave Terraform state, but the key ring and key names are
# permanently reserved in the project.

# Enable the KMS API when CMEK is used (idempotent if already enabled).
resource "google_project_service" "cloudkms" {
  count              = var.cmek.enable ? 1 : 0
  project            = var.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_kms_key_ring" "fleet" {
  count    = var.cmek.enable && var.cmek.create_kms ? 1 : 0
  project  = var.project_id
  name     = var.cmek.kms_key_ring
  location = var.location # co-located with GCS buckets so CMEK works

  depends_on = [google_project_service.cloudkms]
}

resource "google_kms_crypto_key" "fleet" {
  count    = var.cmek.enable && var.cmek.create_kms ? 1 : 0
  name     = var.cmek.kms_crypto_key
  key_ring = google_kms_key_ring.fleet[0].id
  purpose  = "ENCRYPT_DECRYPT"
}

locals {
  # Full resource path for the crypto key, whether Terraform created it or is
  # referencing an existing one. Downstream resources should reference this
  # local rather than the raw var.cmek fields.
  kms_crypto_key_id = var.cmek.enable ? (
    var.cmek.create_kms
    ? google_kms_crypto_key.fleet[0].id
    : "projects/${var.project_id}/locations/${var.location}/keyRings/${var.cmek.kms_key_ring}/cryptoKeys/${var.cmek.kms_crypto_key}"
  ) : null
}

# GCS service agent (service-<project_number>@gs-project-accounts.iam.gserviceaccount.com).
# This is the identity GCS uses to encrypt/decrypt objects when a bucket has CMEK enabled —
# it is NOT the user's service account. Reading this data source also triggers
# provisioning of the agent if it doesn't exist yet.
data "google_storage_project_service_account" "gcs_account" {
  count   = var.cmek.enable ? 1 : 0
  project = var.project_id
}

# Grant the GCS service agent permission to use the CMEK key.
# Without this, bucket creation fails with:
#   "Permission denied on Cloud KMS key. Please ensure that your Cloud Storage
#    service account has been authorized to use this key."
resource "google_kms_crypto_key_iam_member" "gcs_cmek" {
  count         = var.cmek.enable ? 1 : 0
  crypto_key_id = local.kms_crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_account[0].email_address}"
}
