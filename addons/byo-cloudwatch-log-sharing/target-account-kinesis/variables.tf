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
    name        = optional(string, "fleet-log-sharing-destination")
    role_name   = optional(string, "fleet-log-sharing-destination-role")
    policy_name = optional(string)
  })
  default = {}

  validation {
    condition = (
      var.cloudwatch_destination.role_name == null ||
      length(trimspace(var.cloudwatch_destination.role_name)) > 0
    )
    error_message = "cloudwatch_destination.role_name must be null or a non-empty string."
  }
}

variable "kinesis" {
  description = "Kinesis stream settings used as the CloudWatch Logs destination target."
  type = object({
    stream_name      = string
    stream_mode      = optional(string, "ON_DEMAND")
    shard_count      = optional(number, 1)
    retention_period = optional(number, 24)
  })

  validation {
    condition     = contains(["ON_DEMAND", "PROVISIONED"], var.kinesis.stream_mode)
    error_message = "kinesis.stream_mode must be one of: ON_DEMAND, PROVISIONED."
  }

  validation {
    condition     = var.kinesis.shard_count >= 1
    error_message = "kinesis.shard_count must be greater than or equal to 1."
  }

  validation {
    condition     = var.kinesis.retention_period >= 24 && var.kinesis.retention_period <= 8760
    error_message = "kinesis.retention_period must be between 24 and 8760 hours."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to created resources that support tags."
  default     = {}
}
