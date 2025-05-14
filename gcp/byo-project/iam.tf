
# -------------------------------------
# Service Account for Cloud Run Service & Job
# -------------------------------------

resource "google_service_account" "fleet_run_sa" {
  project      = var.project_id
  account_id   = "${var.prefix}-run-sa"
  display_name = "Service Account for Fleet Cloud Run Service and Jobs"
}

resource "google_project_iam_member" "fleet_run_sa_sql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# Recommended for Cloud Run standard logging
resource "google_project_iam_member" "fleet_run_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}

# Recommended for Cloud Run standard metrics
resource "google_project_iam_member" "fleet_run_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.fleet_run_sa.email}"
}


resource "google_secret_manager_secret_iam_member" "fleet_run_sa_db_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"

  depends_on = [google_secret_manager_secret.database_password]
}

resource "google_secret_manager_secret_iam_member" "fleet_run_sa_private_key_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.private_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet_run_sa.email}"

  depends_on = [google_secret_manager_secret.private_key]
}

