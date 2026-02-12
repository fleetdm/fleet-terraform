variable "subscription" {
  description = "CloudWatch Logs subscription configuration for sharing a source log group to a cross-account destination."
  type = object({
    log_group_name       = string
    destination_arn      = string
    filter_name          = optional(string, "fleet-log-sharing")
    filter_pattern       = optional(string, "")
    destination_type     = optional(string, "firehose")
    kinesis_distribution = optional(string, "ByLogStream")
  })

  validation {
    condition     = contains(["firehose", "kinesis"], var.subscription.destination_type)
    error_message = "subscription.destination_type must be one of: firehose, kinesis."
  }

  validation {
    condition     = contains(["ByLogStream", "Random"], var.subscription.kinesis_distribution)
    error_message = "subscription.kinesis_distribution must be one of: ByLogStream, Random."
  }
}
