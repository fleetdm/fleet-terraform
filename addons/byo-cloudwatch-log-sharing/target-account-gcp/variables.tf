variable "project_id" {
  type        = string
  description = "Optional GCP project ID where resources will be created. If omitted, the module uses the active Google provider project."
  default     = ""
}

variable "pubsub" {
  description = "Pub/Sub topic and subscription settings for incoming Fleet log events."
  type = object({
    topic_name                 = optional(string, "fleet-cloudwatch-logs")
    subscription_name          = optional(string, "fleet-cloudwatch-logs-to-gcs")
    ack_deadline_seconds       = optional(number, 20)
    message_retention_duration = optional(string, "604800s")
  })
  default = {}

  validation {
    condition     = length(trimspace(var.pubsub.topic_name)) > 0
    error_message = "pubsub.topic_name must not be empty."
  }

  validation {
    condition     = length(trimspace(var.pubsub.subscription_name)) > 0
    error_message = "pubsub.subscription_name must not be empty."
  }

  validation {
    condition     = var.pubsub.ack_deadline_seconds >= 10 && var.pubsub.ack_deadline_seconds <= 600
    error_message = "pubsub.ack_deadline_seconds must be between 10 and 600 seconds."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*s$", var.pubsub.message_retention_duration))
    error_message = "pubsub.message_retention_duration must be a duration string ending in 's', for example '604800s'."
  }
}

variable "service_account" {
  description = "Service account used by the AWS bridge Lambda to publish to Pub/Sub."
  type = object({
    account_id   = optional(string, "fleet-cloudwatch-pubsub-publisher")
    display_name = optional(string, "Fleet CloudWatch Pub/Sub Publisher")
    description  = optional(string, "Publishes Fleet CloudWatch log events to a customer-managed Pub/Sub topic")
    create_key   = optional(bool, true)
  })
  default = {}

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28}[a-z0-9])$", var.service_account.account_id))
    error_message = "service_account.account_id must be 6-30 chars, start with a letter, and use lowercase letters, numbers, or hyphens."
  }

  validation {
    condition     = length(trimspace(var.service_account.display_name)) > 0
    error_message = "service_account.display_name must not be empty."
  }
}

variable "gcs" {
  description = "Google Cloud Storage destination for delivered Pub/Sub log files."
  type = object({
    bucket_name   = string
    location      = optional(string, "US")
    storage_class = optional(string, "STANDARD")
    force_destroy = optional(bool, false)
  })

  validation {
    condition     = length(trimspace(var.gcs.bucket_name)) > 0
    error_message = "gcs.bucket_name must not be empty."
  }
}

variable "delivery" {
  description = "Pub/Sub Cloud Storage subscription delivery settings."
  type = object({
    filename_prefix = optional(string, "fleet-cloudwatch-logs/")
    filename_suffix = optional(string, ".jsonl")
    max_duration    = optional(string, "300s")
    max_bytes       = optional(number, 10485760)
  })
  default = {}

  validation {
    condition     = can(regex("^[1-9][0-9]*s$", var.delivery.max_duration))
    error_message = "delivery.max_duration must be a duration string ending in 's', for example '300s'."
  }

  validation {
    condition     = var.delivery.max_bytes >= 1024 && var.delivery.max_bytes <= 1073741824
    error_message = "delivery.max_bytes must be between 1024 and 1073741824 bytes."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels to apply to resources that support labels."
  default     = {}
}
