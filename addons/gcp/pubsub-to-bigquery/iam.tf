data "google_project" "project" {
  project_id = var.project_id
}

# Service account used as the Cloud Run service identity.
# Needs BQ dataEditor + jobUser to write rows.
resource "google_service_account" "ingest_sa" {
  project      = var.project_id
  account_id   = "fleet-pubsub-bq-sa"
  display_name = "Fleet PubSub→BQ Ingest Service"
  description  = "Identity for the fleet-pubsub-bq Cloud Run service"
}

# Service account that PubSub uses to generate OIDC tokens for push auth.
resource "google_service_account" "pubsub_invoker_sa" {
  project      = var.project_id
  account_id   = "fleet-pubsub-invoker-sa"
  display_name = "Fleet PubSub Push Invoker"
  description  = "Used by PubSub push subscriptions to authenticate against the ingest Cloud Run service"
}

# Allow PubSub service agent to create OIDC tokens for the invoker SA.
# Required for projects created before April 8, 2021; harmless for newer projects.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pubsub_invoker_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# BQ dataEditor on the dataset lets the ingest SA insert rows.
resource "google_bigquery_dataset_iam_member" "ingest_sa_editor" {
  project    = local.bq_project_id
  dataset_id = google_bigquery_dataset.fleet_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.ingest_sa.email}"
}

# BQ jobUser at project level lets the ingest SA run jobs (needed for streaming inserts).
resource "google_project_iam_member" "ingest_sa_bq_job_user" {
  project = local.bq_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.ingest_sa.email}"
}

# Standard Cloud Run logging
resource "google_project_iam_member" "ingest_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ingest_sa.email}"
}
