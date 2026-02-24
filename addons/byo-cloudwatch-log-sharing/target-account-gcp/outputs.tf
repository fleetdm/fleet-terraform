output "bridge" {
  description = "Values to share with the AWS bridge module configuration."
  value = {
    project_id = local.effective_project_id
    topic_id   = google_pubsub_topic.fleet_logs.name
  }
}

output "pubsub" {
  description = "Pub/Sub resource details for the log intake topic and GCS sink subscription."
  value = {
    topic_name         = google_pubsub_topic.fleet_logs.name
    topic_id           = google_pubsub_topic.fleet_logs.id
    topic_qualified_id = google_pubsub_topic.fleet_logs.id

    subscription_name         = google_pubsub_subscription.gcs_sink.name
    subscription_id           = google_pubsub_subscription.gcs_sink.id
    subscription_qualified_id = google_pubsub_subscription.gcs_sink.id
  }
}

output "storage" {
  description = "Google Cloud Storage destination details."
  value = {
    bucket_name = google_storage_bucket.fleet_logs.name
    bucket_url  = google_storage_bucket.fleet_logs.url
  }
}

output "publisher_service_account" {
  description = "Publisher service-account details used by the AWS Lambda bridge."
  value = {
    email      = google_service_account.publisher.email
    account_id = google_service_account.publisher.account_id
    member     = "serviceAccount:${google_service_account.publisher.email}"
  }
}

output "publisher_credentials_json" {
  description = "Sensitive Google service-account credentials JSON to store in AWS Secrets Manager for the bridge Lambda."
  value       = var.service_account.create_key ? base64decode(google_service_account_key.publisher[0].private_key) : null
  sensitive   = true
}
