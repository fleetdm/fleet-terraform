output "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs"
  value       = google_pubsub_topic.result.name
}

output "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs"
  value       = google_pubsub_topic.status.name
}

output "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs"
  value       = google_pubsub_topic.audit.name
}

output "fleet_env_vars" {
  description = "Map of Fleet env vars to enable PubSub logging. Merge into fleet_config.extra_env_vars."
  value = {
    FLEET_OSQUERY_RESULT_LOG_PLUGIN = "pubsub"
    FLEET_OSQUERY_STATUS_LOG_PLUGIN = "pubsub"
    FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
    FLEET_PUBSUB_PROJECT            = var.project_id
    FLEET_PUBSUB_RESULT_TOPIC       = google_pubsub_topic.result.name
    FLEET_PUBSUB_STATUS_TOPIC       = google_pubsub_topic.status.name
    FLEET_PUBSUB_AUDIT_TOPIC        = google_pubsub_topic.audit.name
    FLEET_PUBSUB_ADD_ATTRIBUTES     = "true"
  }
}
