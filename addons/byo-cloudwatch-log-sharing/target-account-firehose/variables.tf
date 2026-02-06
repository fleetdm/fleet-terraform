variable "source_account_ids" {
  type        = list(string)
  description = "AWS account IDs allowed to create subscription filters to this destination."

  validation {
    condition     = length(var.source_account_ids) > 0
    error_message = "source_account_ids must include at least one AWS account ID."
  }
}

variable "destination_policy_source_organization_id" {
  type        = string
  description = "Optional AWS Organization ID allowed to subscribe to this destination."
  default     = ""
}

variable "cloudwatch_destination" {
  description = "CloudWatch Logs destination settings in the source log-group region."
  type = object({
    name      = optional(string, "fleet-log-sharing-firehose-destination")
    role_name = optional(string, "fleet-log-sharing-firehose-destination-role")
  })
  default = {}
}

variable "firehose" {
  description = "Firehose delivery stream settings used as the CloudWatch Logs destination target."
  type = object({
    delivery_stream_name = string
    role_name            = optional(string, "fleet-log-sharing-firehose-delivery-role")
    buffering_size       = optional(number, 5)
    buffering_interval   = optional(number, 300)
    compression_format   = optional(string, "GZIP")
    s3_prefix            = optional(string, "fleet-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/")
    s3_error_prefix      = optional(string, "fleet-logs-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/")
  })

  validation {
    condition     = var.firehose.buffering_size >= 1 && var.firehose.buffering_size <= 128
    error_message = "firehose.buffering_size must be between 1 and 128 MB."
  }

  validation {
    condition     = var.firehose.buffering_interval >= 0 && var.firehose.buffering_interval <= 900
    error_message = "firehose.buffering_interval must be between 0 and 900 seconds."
  }

  validation {
    condition = contains([
      "UNCOMPRESSED",
      "GZIP",
      "ZIP",
      "Snappy",
      "HADOOP_SNAPPY",
    ], var.firehose.compression_format)
    error_message = "firehose.compression_format must be one of: UNCOMPRESSED, GZIP, ZIP, Snappy, HADOOP_SNAPPY."
  }
}

variable "s3" {
  description = "S3 configuration for Firehose delivered logs."
  type = object({
    bucket_name   = string
    force_destroy = optional(bool, false)
  })
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to created resources that support tags."
  default     = {}
}
