resource "google_storage_hmac_key" "key" {
  project               = var.project_id
  service_account_email = google_service_account.fleet_run_sa.email
}

resource "google_storage_bucket" "software_installers" {
  project       = var.project_id
  name          = var.fleet_config.installers_bucket_name
  location      = var.location
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "hmac_sa_storage_admin" {
  bucket = google_storage_bucket.software_installers.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# File carving bucket. Fleet writes osquery file-carve results here via its
# S3-compatible client pointed at GCS. Software title icons and MDM
# bootstrap packages reuse the software_installers bucket above under
# hard-coded sub-prefixes, so no separate buckets are needed for those.
resource "google_storage_bucket" "carves" {
  project       = var.project_id
  name          = var.fleet_config.carves_bucket_name
  location      = var.location
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "hmac_sa_carves_admin" {
  bucket = google_storage_bucket.carves.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}