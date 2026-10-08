output "bq_dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.fleet_logs.dataset_id
}

output "service_url" {
  description = "URL of the fleet-pubsub-bq Cloud Run service"
  value       = google_cloud_run_v2_service.ingest.uri
}
