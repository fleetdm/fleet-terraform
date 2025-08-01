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

variable "snowflake_shared" {
  description = "Shared configurations among each logging destination"
  type = object({
    account_url    = string
    private_key    = string
    key_passphrase = optional(string, null)
    user           = string
    snowflake_role_configuration = object({
      enabled        = bool
      snowflake_role = optional(string, null)
    })
    snowflake_vpc_configuration = optional(object({
      private_link_vpce_id = string
      }), {
      private_link_vpce_id = null
    })
  })
}

variable "log_destinations" {
  description = "A map of configurations for Snowflake Firehose delivery streams."
  type = map(object({
    name                   = string
    database               = string
    schema                 = string
    table                  = string
    buffering_size         = number
    buffering_interval     = number
    s3_buffering_size      = number
    s3_buffering_interval  = number
    s3_error_output_prefix = optional(string, null)
    data_loading_option    = optional(string, "JSON_MAPPING")
    content_column_name    = optional(string, null)
    metadata_column_name   = optional(string, null)
  }))
  default = {
    results = {
      name                  = "fleet-osquery-results-snowflake"
      database              = "fleet"
      schema                = "fleet_schema"
      table                 = "osquery_results"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
    },
    status = {
      name                  = "fleet-osquery-status-snowflake"
      database              = "fleet"
      schema                = "fleet_schema"
      table                 = "osquery_status"
      user                  = "fleet"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
    },
    audit = {
      name                  = "fleet-audit-snowflake"
      database              = "fleet"
      schema                = "fleet_schema"
      table                 = "fleet_audit"
      buffering_size        = 2
      buffering_interval    = 60
      s3_buffering_size     = 10
      s3_buffering_interval = 400
    }
  }
}

variable "compression_format" {
  default     = "UNCOMPRESSED"
  description = "Compression format for the Firehose delivery stream"
}
