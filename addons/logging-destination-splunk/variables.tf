variable "iam_policy_name" {
  type    = string
  default = "splunk-firehose-policy"
}

variable "s3_bucket_config" {
  type = object({
    name_prefix  = optional(string, "fleet-splunk-failure")
    expires_days = optional(number, 1)
  })
  default = {
    name_prefix  = "fleet-splunk-failure"
    expires_days = 1
  }
  description = "Configuration for the S3 bucket used to store failed Splunk delivery attempts"
}

variable "log_destinations" {
  description = "A map of configurations for Splunk Firehose delivery streams."
  type = map(object({
    # hec endpoint/token are logically optional but validated to enforce 
    name                        = string
    hec_endpoint                = optional(string)
    hec_token                   = optional(string)
    hec_acknowledgement_timeout = optional(number, 600)
    hec_endpoint_type           = optional(string, "Raw")
    s3_buffering_size           = optional(number, 2)
    s3_buffering_interval       = optional(number, 400)
    s3_error_output_prefix      = optional(string, null)

  }))
  default = {
    results = {
      name                        = "fleet-osquery-results-splunk"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "results/"
    },
    status = {
      name                        = "fleet-osquery-status-splunk"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "status/"
    },
    audit = {
      name                        = "fleet-audit-splunk"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "audit/"
    }
  }
  validation {
    condition     = alltrue([for _, ds in var.log_destinations : ds.hec_endpoint != null && ds.hec_endpoint != ""])
    error_message = "Each delivery stream must supply a non-empty `hec_endpoint`."
  }
  validation {
    condition     = alltrue([for _, ds in var.log_destinations : ds.hec_token != null && ds.hec_token != ""])
    error_message = "Each delivery stream must supply a non-empty `hec_token`."
  }
}



variable "compression_format" {
  default     = "UNCOMPRESSED"
  description = "Compression format for the Firehose delivery stream"
}
