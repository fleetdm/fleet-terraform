# -------------------------------------
# Cloud KMS for CMEK (Customer-Managed Encryption Keys)
# -------------------------------------
# Two modes, gated by cmek.create_kms:
#   - create_kms = false (default): key ring and crypto key must already exist in
#     the project at the region. Terraform only references them.
#   - create_kms = true: Terraform creates the key ring and crypto key in this
#     project/region using the provided names.
#
# The resolved crypto key path is exported via local.kms_crypto_key_id and is
# used only by the GCS buckets. Cloud SQL, Memorystore, Cloud Run and Secret
# Manager use their own caller-supplied keys (cmek.<service>, bottom of file).
#
# WARNING: key rings and crypto keys cannot be truly deleted in GCP. On
# `terraform destroy`, key versions are scheduled for destruction (default 30 days)
# and the resources leave Terraform state, but the key ring and key names are
# permanently reserved in the project.

# Enable the KMS API when CMEK is used (idempotent if already enabled): either
# the legacy GCS setting or any of the per-service consumers below.
resource "google_project_service" "cloudkms" {
  count              = var.cmek.enable || local.cmek_any_consumer ? 1 : 0
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

# -------------------------------------
# Per-service CMEK consumers (Cloud SQL, Memorystore, Cloud Run, Secret Manager)
# -------------------------------------
# Independent of the legacy enable/create_kms settings above, which remain
# GCS-only. Each consumer is opted in by setting its cmek.<service> object; the
# key IDs are caller-supplied (never created here) and may be unknown at plan
# time, so every count/for_each below is gated on object presence or on
# var.replicate_secrets only, never on a key ID value.
#
# Each grant goes to the Google-managed service agent that performs the
# encryption, never to the Fleet application service account:
#   Cloud SQL       service-N@gcp-sa-cloud-sql.iam.gserviceaccount.com
#   Memorystore     service-N@cloud-redis.iam.gserviceaccount.com
#   Cloud Run       service-N@serverless-robot-prod.iam.gserviceaccount.com
#   Secret Manager  service-N@gcp-sa-secretmanager.iam.gserviceaccount.com
#
# Service-agent readiness: the Cloud SQL and Secret Manager agents are not
# guaranteed to exist until first use, so they are provisioned explicitly via
# google_project_service_identity (google-beta). The Memorystore and Cloud Run
# agents are created when redis.googleapis.com / run.googleapis.com are
# enabled; the root module enables those (project factory, or
# manage_existing_project_apis = true) before this module runs. When calling
# this module directly on an existing project, enable those APIs first.
#
# The grants are additive (iam_member). Different consumers may share one key:
# each consumer grants a different member, so no two grant resources manage the
# same (key, role, member) binding.

locals {
  cmek_any_consumer = anytrue([
    var.cmek.cloud_sql != null,
    var.cmek.redis != null,
    var.cmek.cloud_run != null,
    var.cmek.secret_manager != null,
  ])

  cmek_cloud_sql_key_id = var.cmek.cloud_sql == null ? null : var.cmek.cloud_sql.kms_key_id
  cmek_redis_key_id     = var.cmek.redis == null ? null : var.cmek.redis.kms_key_id
  cmek_cloud_run_key_id = var.cmek.cloud_run == null ? null : var.cmek.cloud_run.kms_key_id

  # Secret Manager key per replication location: { global = key } for
  # automatic replication, { <region> = key } per replicate_secrets region for
  # user-managed replication, {} when not opted in. Keys come from
  # var.replicate_secrets (always known), so unknown key IDs stay plannable.
  # Variable validation guarantees every region has a key.
  cmek_secret_manager_key_ids = var.cmek.secret_manager == null ? {} : (
    length(var.replicate_secrets) == 0
    ? { global = var.cmek.secret_manager.kms_key_id }
    : { for r in toset(var.replicate_secrets) : r => var.cmek.secret_manager.replica_kms_key_ids[r] }
  )
}

# Project number for the service-agent emails. Only read when a per-service
# consumer is opted in, so default and legacy-only plans are unchanged.
data "google_project" "cmek" {
  count      = local.cmek_any_consumer ? 1 : 0
  project_id = var.project_id
}

locals {
  cmek_project_number = local.cmek_any_consumer ? data.google_project.cmek[0].number : null
}

resource "google_project_service_identity" "cloud_sql" {
  count    = var.cmek.cloud_sql != null ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "sqladmin.googleapis.com"
}

resource "google_project_service_identity" "secret_manager" {
  count    = var.cmek.secret_manager != null ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "cloud_sql_cmek" {
  count         = var.cmek.cloud_sql != null ? 1 : 0
  crypto_key_id = local.cmek_cloud_sql_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${local.cmek_project_number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"

  depends_on = [
    google_project_service.cloudkms,
    google_project_service_identity.cloud_sql,
  ]
}

resource "google_kms_crypto_key_iam_member" "redis_cmek" {
  count         = var.cmek.redis != null ? 1 : 0
  crypto_key_id = local.cmek_redis_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${local.cmek_project_number}@cloud-redis.iam.gserviceaccount.com"

  depends_on = [google_project_service.cloudkms]
}

resource "google_kms_crypto_key_iam_member" "cloud_run_cmek" {
  count         = var.cmek.cloud_run != null ? 1 : 0
  crypto_key_id = local.cmek_cloud_run_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${local.cmek_project_number}@serverless-robot-prod.iam.gserviceaccount.com"

  depends_on = [google_project_service.cloudkms]
}

resource "google_kms_crypto_key_iam_member" "secret_manager_cmek" {
  for_each      = local.cmek_secret_manager_key_ids
  crypto_key_id = each.value
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${local.cmek_project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com"

  depends_on = [
    google_project_service.cloudkms,
    google_project_service_identity.secret_manager,
  ]
}
