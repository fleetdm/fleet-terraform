resource "google_pubsub_topic" "result" {
  project = var.project_id
  name    = var.result_topic_name
}

resource "google_pubsub_topic" "status" {
  project = var.project_id
  name    = var.status_topic_name
}

resource "google_pubsub_topic" "audit" {
  project = var.project_id
  name    = var.audit_topic_name
}

resource "google_pubsub_topic_iam_member" "fleet_result_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.result.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}

resource "google_pubsub_topic_iam_member" "fleet_status_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.status.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}

resource "google_pubsub_topic_iam_member" "fleet_audit_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.audit.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.fleet_sa_email}"
}
