variable "s3_bucket_config" {
  type = object({
    name_prefix  = optional(string, "fleet-snowflake-failure")
    expires_days = optional(number, 1)
  })
  default = {
    name_prefix  = "fleet-snowflake-failure"
    expires_days = 1
  }
  description = "Configuration for the S3 bucket used to store failed Snowflake delivery attempts"
}

variable "log_destinations" {
  description = "A map of configurations for Snowflake Firehose delivery streams."
  type = map(object({
    name                  = string
    account_url           = string
    database              = string
    private_key           = string
    schema                = string
    table                 = string
    user                  = string
    buffering_size        = number
    buffering_interval    = number
    s3_buffering_size     = number
    s3_buffering_interval = number
    })), {})
  }))
  default = {
    results = {
      name                  = "fleet-osquery-results-snowflake"
      database              = "fleet"
      schema                = "osquery-results"
      table                 = "osquery-results"
      user                  = "fleet"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
      content_encoding      = "NONE"
      common_attributes     = []
    },
    status = {
      name                  = "fleet-osquery-status-snowflake"
      database              = "fleet"
      schema                = "osquery-results"
      table                 = "osquery-results"
      user                  = "fleet"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
      content_encoding      = "NONE"
      common_attributes     = []
    },
    audit = {
      name                  = "fleet-audit-snowflake"
      database              = "fleet"
      schema                = "osquery-results"
      table                 = "osquery-results"
      user                  = "fleet"
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
