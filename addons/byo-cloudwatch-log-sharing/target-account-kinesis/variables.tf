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
  default     = "fleet-log-sharing-destination"
}

variable "destination_role_name" {
  type        = string
  description = "IAM role name assumed by CloudWatch Logs to write into the Kinesis stream."
  default     = "fleet-log-sharing-destination-role"
}

variable "kinesis_stream_name" {
  type        = string
  description = "Kinesis Data Stream name that receives shared log events."
}

variable "kinesis_stream_mode" {
  type        = string
  description = "Kinesis stream mode. Valid values: ON_DEMAND or PROVISIONED."
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "PROVISIONED"], var.kinesis_stream_mode)
    error_message = "kinesis_stream_mode must be one of: ON_DEMAND, PROVISIONED."
  }
}

variable "kinesis_shard_count" {
  type        = number
  description = "Shard count when kinesis_stream_mode is PROVISIONED."
  default     = 1

  validation {
    condition     = var.kinesis_shard_count >= 1
    error_message = "kinesis_shard_count must be greater than or equal to 1."
  }
}

variable "kinesis_retention_period" {
  type        = number
  description = "Retention period for the Kinesis stream in hours."
  default     = 24

  validation {
    condition     = var.kinesis_retention_period >= 24 && var.kinesis_retention_period <= 8760
    error_message = "kinesis_retention_period must be between 24 and 8760 hours."
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
