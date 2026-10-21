variable "project_id" {
  description = "GCP project ID where PubSub topics are created"
  type        = string
}

variable "fleet_sa_email" {
  description = "Email of the Fleet Cloud Run service account (fleet-run-sa). Granted pubsub.publisher on all topics."
  type        = string
}

variable "result_topic_name" {
  description = "Name of the PubSub topic for osquery result logs"
  type        = string
  default     = "fleet-result-logs"
}

variable "status_topic_name" {
  description = "Name of the PubSub topic for osquery status logs"
  type        = string
  default     = "fleet-status-logs"
}

variable "audit_topic_name" {
  description = "Name of the PubSub topic for Fleet audit logs"
  type        = string
  default     = "fleet-audit-logs"
}
