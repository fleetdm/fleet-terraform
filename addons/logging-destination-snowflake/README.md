# Logging Destination: Snowflake

This addon configures AWS Kinesis Firehose to send Fleet's osquery logs to Snowflake. It creates:

1. Kinesis Firehose delivery streams for each log type (results, status, and audit)
2. A single S3 bucket for storing all failed delivery attempts
3. IAM roles and policies for the Firehose streams to access the S3 bucket
4. An IAM policy for Fleet to access the Firehose streams

## How to use

```hcl
module "snowflake-logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-snowflake?depth=1&ref=tf-mod-addon-logging-destination-snowflake-v1.0.0"

  s3_bucket_config = {
    name_prefix  = "fleet-snowflake-failure"
    expires_days = 5
  }
  snowflake_shared = {
    account_url    = "https://<snowflake_url>.snowflakecomputing.com"
    private_key    = "<pass this in securely>"
    key_passphrase = "<pass this in securely>"
    user           = "fleet_user"
    snowflake_role_configuration = {
      enabled        = true
      snowflake_role = "fleet_cloud_rl"
    }
  }

  log_destinations = {
    results = {
      name                   = "fleet-osquery-results-snowflake"
      database               = "fleet_cloud_db"
      schema                 = "fleet_cloud_schema"
      table                  = "osquery_results"
      buffering_size         = 2
      buffering_interval     = 60
      s3_buffering_size      = 10
      s3_buffering_interval  = 400
      s3_buffering_interval  = 400
      s3_error_output_prefix = "results/"
      data_loading_option    = "VARIANT_CONTENT_MAPPING"
      content_column_name    = "results"
    },
    status = {
      name                   = "fleet-osquery-status-snowflake"
      database               = "fleet_cloud_db"
      schema                 = "fleet_cloud_schema"
      table                  = "osquery_status"
      user                   = "fleet"
      buffering_size         = 2
      buffering_interval     = 60
      s3_buffering_size      = 10
      s3_buffering_interval  = 400
      s3_buffering_interval  = 400
      s3_error_output_prefix = "status/"
      data_loading_option    = "VARIANT_CONTENT_MAPPING"
      content_column_name    = "status"
    },
    audit = {
      name                   = "fleet-audit-snowflake"
      database               = "fleet_cloud_db"
      schema                 = "fleet_cloud_schema"
      table                  = "fleet_audit"
      buffering_size         = 2
      buffering_interval     = 60
      s3_buffering_size      = 10
      s3_buffering_interval  = 400
      s3_error_output_prefix = "audit/"
    }
  }
}

```

Then you can use the module's outputs in your Fleet configuration:

```hcl
module "fleet" {
  source = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.16.4"
  certificate_arn = module.acm.acm_certificate_arn

  vpc = {
    name = local.vpc_name
    # azs = ["us-east-2a", "us-east-2b", "us-east-2c"]
  }

  fleet_config = {
    image = "fleetdm/fleet:v4.70.1"
    autoscaling = {
      min_capacity = 2
      max_capacity = 5
    }
    mem = 4096
    cpu = 512
    extra_environment_variables = merge(
      local.fleet_environment_variables,
      # Uncomment to enable Snowflake logging
      module.snowflake-logging.fleet_extra_environment_variables
    )
    extra_iam_policies = concat(
      # Uncomment to enable Snowflake logging
      module.snowflake-logging.fleet_extra_iam_policies,
    )
  }

  # ... other Fleet configuration ...
}
```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.snowflake](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_s3_bucket.snowflake-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.snowflake-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.snowflake-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.snowflake-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_iam_policy_document.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_compression_format"></a> [compression\_format](#input\_compression\_format) | Compression format for the Firehose delivery stream | `string` | `"UNCOMPRESSED"` | no |
| <a name="input_log_destinations"></a> [log\_destinations](#input\_log\_destinations) | A map of configurations for Snowflake Firehose delivery streams. | <pre>map(object({<br/>    name                   = string<br/>    database               = string<br/>    schema                 = string<br/>    table                  = string<br/>    buffering_size         = number<br/>    buffering_interval     = number<br/>    s3_buffering_size      = number<br/>    s3_buffering_interval  = number<br/>    s3_error_output_prefix = optional(string, null)<br/>    data_loading_option    = optional(string, "JSON_MAPPING")<br/>    content_column_name    = optional(string, null)<br/>    metadata_column_name   = optional(string, null)<br/>  }))</pre> | <pre>{<br/>  "audit": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "database": "fleet",<br/>    "name": "fleet-audit-snowflake",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "schema": "fleet_schema",<br/>    "table": "fleet_audit"<br/>  },<br/>  "results": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "database": "fleet",<br/>    "name": "fleet-osquery-results-snowflake",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "schema": "fleet_schema",<br/>    "table": "osquery_results"<br/>  },<br/>  "status": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "database": "fleet",<br/>    "name": "fleet-osquery-status-snowflake",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "schema": "fleet_schema",<br/>    "table": "osquery_status",<br/>    "user": "fleet"<br/>  }<br/>}</pre> | no |
| <a name="input_s3_bucket_config"></a> [s3\_bucket\_config](#input\_s3\_bucket\_config) | Configuration for the S3 bucket used to store failed Snowflake delivery attempts | <pre>object({<br/>    name_prefix  = optional(string, "fleet-snowflake-failure")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name_prefix": "fleet-snowflake-failure"<br/>}</pre> | no |
| <a name="input_snowflake_shared"></a> [snowflake\_shared](#input\_snowflake\_shared) | Shared configurations among each logging destination | <pre>object({<br/>    account_url    = string<br/>    private_key    = string<br/>    key_passphrase = optional(string, null)<br/>    user           = string<br/>    snowflake_role_configuration = object({<br/>      enabled        = bool<br/>      snowflake_role = optional(string, null)<br/>    })<br/>    snowflake_vpc_configuration = optional(object({<br/>      private_link_vpce_id = string<br/>      }), {<br/>      private_link_vpce_id = null<br/>    })<br/>  })</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | Environment variables to configure Fleet to use Snowflake logging via Firehose |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | IAM policies required for Fleet to log to Snowflake via Firehose |
