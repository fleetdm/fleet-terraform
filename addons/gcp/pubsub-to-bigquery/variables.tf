variable "project_id" {
  description = "GCP project ID for PubSub subscriptions and Cloud Run service"
  type        = string
}

variable "bq_project_id" {
  description = "GCP project ID for BigQuery dataset and tables. Defaults to project_id."
  type        = string
  default     = null
}

variable "region" {
  description = "GCP region for Cloud Run service"
  type        = string
  default     = "us-central1"
}

variable "image" {
  description = "Full Artifact Registry image URL and tag for the fleet-pubsub-bq service (e.g. us-central1-docker.pkg.dev/PROJECT/fleet/fleet-pubsub-bq:v1.0.0)"
  type        = string
}

variable "bq_dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "fleet_logs"
}

variable "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs. Use fleet-pubsub module output."
  type        = string
}

variable "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs. Use fleet-pubsub module output."
  type        = string
}

variable "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs. Use fleet-pubsub module output."
  type        = string
}

locals {
  bq_project_id            = coalesce(var.bq_project_id, var.project_id)
  result_subscription_name = "${var.result_topic_name}-sub"
  status_subscription_name = "${var.status_topic_name}-sub"
  audit_subscription_name  = "${var.audit_topic_name}-sub"
}
