variable "s3_bucket_config" {
  type = object({
    name_prefix  = optional(string, "fleet-datadog-failure")
    expires_days = optional(number, 1)
  })
  default = {
    name_prefix  = "fleet-datadog-failure"
    expires_days = 1
  }
  description = "Configuration for the S3 bucket used to store failed Datadog delivery attempts"
}

variable "log_destinations" {
  description = "A map of configurations for Datadog Firehose delivery streams."
  type = map(object({
    name                  = string
    buffering_size        = number
    buffering_interval    = number
    s3_buffering_size     = number
    s3_buffering_interval = number
    content_encoding      = string
    common_attributes = optional(list(object({
      name  = string
      value = string
    })), [])
  }))
  default = {
    results = {
      name                  = "fleet-osquery-results-datadog"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
      content_encoding      = "NONE"
      common_attributes     = []
    },
    status = {
      name                  = "fleet-osquery-status-datadog"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
      content_encoding      = "NONE"
      common_attributes     = []
    },
    audit = {
      name                  = "fleet-audit-datadog"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
      content_encoding      = "NONE"
      common_attributes     = []
    }
  }
}

variable "compression_format" {
  default     = "UNCOMPRESSED"
  description = "Compression format for the Firehose delivery stream"
}

variable "datadog_url" {
  type        = string
  description = "Datadog HTTP API endpoint URL"
}

variable "datadog_api_key" {
  type        = string
  description = "Datadog API key for authentication"
  sensitive   = true
}
