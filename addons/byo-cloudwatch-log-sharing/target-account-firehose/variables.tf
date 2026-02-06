variable "source_account_ids" {
  type        = list(string)
  description = "AWS account IDs allowed to create subscription filters to this destination."

  validation {
    condition     = length(var.source_account_ids) > 0
    error_message = "source_account_ids must include at least one AWS account ID."
  }
}

variable "destination_name" {
  type        = string
  description = "Name of the CloudWatch Logs destination created in the destination provider region."
  default     = "fleet-log-sharing-firehose-destination"
}

variable "destination_role_name" {
  type        = string
  description = "IAM role name assumed by CloudWatch Logs to write into Firehose."
  default     = "fleet-log-sharing-firehose-destination-role"
}

variable "firehose_delivery_stream_name" {
  type        = string
  description = "Firehose delivery stream name that receives shared log events."
}

variable "firehose_role_name" {
  type        = string
  description = "IAM role name assumed by Firehose to deliver records to S3."
  default     = "fleet-log-sharing-firehose-delivery-role"
}

variable "s3_bucket_name" {
  type        = string
  description = "S3 bucket name for Firehose-delivered logs."
}

variable "s3_force_destroy" {
  type        = bool
  description = "Whether to allow Terraform to destroy a non-empty S3 bucket."
  default     = false
}

variable "s3_prefix" {
  type        = string
  description = "S3 prefix for delivered records."
  default     = "fleet-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
}

variable "s3_error_output_prefix" {
  type        = string
  description = "S3 prefix for Firehose delivery errors."
  default     = "fleet-logs-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
}

variable "buffering_size" {
  type        = number
  description = "Buffer size in MB before Firehose delivers to S3."
  default     = 5

  validation {
    condition     = var.buffering_size >= 1 && var.buffering_size <= 128
    error_message = "buffering_size must be between 1 and 128 MB."
  }
}

variable "buffering_interval" {
  type        = number
  description = "Buffer interval in seconds before Firehose delivers to S3."
  default     = 300

  validation {
    condition     = var.buffering_interval >= 0 && var.buffering_interval <= 900
    error_message = "buffering_interval must be between 0 and 900 seconds."
  }
}

variable "compression_format" {
  type        = string
  description = "Compression format for Firehose S3 delivery."
  default     = "GZIP"

  validation {
    condition = contains([
      "UNCOMPRESSED",
      "GZIP",
      "ZIP",
      "Snappy",
      "HADOOP_SNAPPY",
    ], var.compression_format)
    error_message = "compression_format must be one of: UNCOMPRESSED, GZIP, ZIP, Snappy, HADOOP_SNAPPY."
  }
}

variable "destination_policy_source_organization_id" {
  type        = string
  description = "Optional AWS Organization ID allowed to subscribe to this destination."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to created resources that support tags."
  default     = {}
}
