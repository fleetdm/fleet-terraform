data "google_client_config" "current" {}

data "google_project" "target" {
  project_id = local.effective_project_id
}

locals {
  effective_project_id       = trimspace(var.project_id) != "" ? var.project_id : data.google_client_config.current.project
  effective_sa_account_id    = trimspace(var.service_account.account_id) != "" ? var.service_account.account_id : "fleet-cwl-pubsub-publisher"
  pubsub_service_agent_email = "service-${data.google_project.target.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic" "fleet_logs" {
  project = local.effective_project_id
  name    = var.pubsub.topic_name
  labels  = var.labels
}

resource "google_service_account" "publisher" {
  project      = local.effective_project_id
  account_id   = local.effective_sa_account_id
  display_name = var.service_account.display_name
  description  = var.service_account.description
}

resource "google_service_account_key" "publisher" {
  count              = var.service_account.create_key ? 1 : 0
  service_account_id = google_service_account.publisher.name
  private_key_type   = "TYPE_GOOGLE_CREDENTIALS_FILE"
}

resource "google_pubsub_topic_iam_member" "publisher" {
  project = local.effective_project_id
  topic   = google_pubsub_topic.fleet_logs.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

resource "google_storage_bucket" "fleet_logs" {
  project       = local.effective_project_id
  name          = var.gcs.bucket_name
  location      = var.gcs.location
  storage_class = var.gcs.storage_class
  force_destroy = var.gcs.force_destroy
  labels        = var.labels

  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "pubsub_writer" {
  bucket = google_storage_bucket.fleet_logs.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${local.pubsub_service_agent_email}"
}

resource "google_storage_bucket_iam_member" "pubsub_bucket_reader" {
  bucket = google_storage_bucket.fleet_logs.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${local.pubsub_service_agent_email}"
}

resource "google_pubsub_subscription" "gcs_sink" {
  project = local.effective_project_id
  name    = var.pubsub.subscription_name
  topic   = google_pubsub_topic.fleet_logs.id

  ack_deadline_seconds       = var.pubsub.ack_deadline_seconds
  message_retention_duration = var.pubsub.message_retention_duration

  cloud_storage_config {
    bucket          = google_storage_bucket.fleet_logs.name
    filename_prefix = var.delivery.filename_prefix
    filename_suffix = var.delivery.filename_suffix
    max_duration    = var.delivery.max_duration
    max_bytes       = var.delivery.max_bytes
  }

  depends_on = [
    google_storage_bucket_iam_member.pubsub_writer,
    google_storage_bucket_iam_member.pubsub_bucket_reader,
  ]
}
