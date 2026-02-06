variable "log_group_name" {
  type        = string
  description = "CloudWatch Logs log group name to subscribe and share to the destination account."
}

variable "destination_arn" {
  type        = string
  description = "ARN of the CloudWatch Logs destination in the target account."
}

variable "filter_name" {
  type        = string
  description = "Subscription filter name created on the source log group."
  default     = "fleet-log-sharing"
}

variable "filter_pattern" {
  type        = string
  description = "Filter pattern used for the subscription. Leave empty to forward the entire log group."
  default     = ""
}

variable "destination_type" {
  type        = string
  description = "Destination backend type. Valid values: firehose or kinesis."
  default     = "firehose"

  validation {
    condition     = contains(["firehose", "kinesis"], var.destination_type)
    error_message = "destination_type must be one of: firehose, kinesis."
  }
}

variable "kinesis_distribution" {
  type        = string
  description = "Kinesis-only distribution mode. Ignored when destination_type is firehose."
  default     = "ByLogStream"

  validation {
    condition     = contains(["ByLogStream", "Random"], var.kinesis_distribution)
    error_message = "kinesis_distribution must be one of: ByLogStream, Random."
  }
}
