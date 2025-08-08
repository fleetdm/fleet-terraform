# Logging Destination: Datadog

This addon configures AWS Kinesis Firehose to send Fleet's osquery logs to Datadog. It creates:

1. Kinesis Firehose delivery streams for each log type (results, status, and audit)
2. A single S3 bucket for storing all failed delivery attempts
3. IAM roles and policies for the Firehose streams to access the S3 bucket
4. An IAM policy for Fleet to access the Firehose streams

## How to use

```hcl
module "datadog-logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-datadog?ref=tf-mod-addon-logging-destination-datadog-v1.0.0"

  datadog_api_key = "your-datadog-api-key"

  # Optional: customize other settings
  # datadog_url = "https://custom-datadog-endpoint.com"
  # s3_bucket_config = {
  #   name_prefix = "custom-bucket-prefix"
  #   expires_days = 7
  # }
  # log_destinations = {
  #   results = {
  #     name = "custom-results-stream-name"
  #     buffering_size = 1
  #     buffering_interval = 60
  #     s3_buffering_size = 10
  #     s3_buffering_interval = 400
  #     common_attributes = [
  #       {
  #         name  = "service"
  #         value = "fleet-osquery-results"
  #       },
  #       {
  #         name  = "environment"
  #         value = "production"
  #       }
  #     ]
  #   },
  #   status = {
  #     name = "custom-status-stream-name"
  #     buffering_size = 1
  #     buffering_interval = 60
  #     s3_buffering_size = 10
  #     s3_buffering_interval = 400
  #     common_attributes = [
  #       {
  #         name  = "service"
  #         value = "fleet-osquery-status"
  #       },
  #       {
  #         name  = "environment"
  #         value = "production"
  #       }
  #     ]
  #   },
  #   audit = {
  #     name = "custom-audit-stream-name"
  #     buffering_size = 1
  #     buffering_interval = 60
  #     s3_buffering_size = 10
  #     s3_buffering_interval = 400
  #     common_attributes = [
  #       {
  #         name  = "service"
  #         value = "fleet-audit"
  #       },
  #       {
  #         name  = "environment"
  #         value = "production"
  #       }
  #     ]
  #   }
  # }
  # compression_format = "GZIP"
}
```

Then you can use the module's outputs in your Fleet configuration:

```hcl
module "fleet" {
  source = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.15.2"
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
      # Uncomment to enable Datadog logging
      module.datadog-logging.fleet_extra_environment_variables
    )
    extra_iam_policies = concat(
      # Uncomment to enable Datadog logging
      module.datadog-logging.fleet_extra_iam_policies,
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
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.8.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.datadog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_s3_bucket.datadog-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.datadog-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.datadog-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.datadog-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_iam_policy_document.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_compression_format"></a> [compression\_format](#input\_compression\_format) | Compression format for the Firehose delivery stream | `string` | `"UNCOMPRESSED"` | no |
| <a name="input_datadog_api_key"></a> [datadog\_api\_key](#input\_datadog\_api\_key) | Datadog API key for authentication | `string` | n/a | yes |
| <a name="input_datadog_url"></a> [datadog\_url](#input\_datadog\_url) | Datadog HTTP API endpoint URL | `string` | n/a | yes |
| <a name="input_log_destinations"></a> [log\_destinations](#input\_log\_destinations) | A map of configurations for Datadog Firehose delivery streams. | <pre>map(object({<br/>    name                  = string<br/>    buffering_size        = number<br/>    buffering_interval    = number<br/>    s3_buffering_size     = number<br/>    s3_buffering_interval = number<br/>    content_encoding      = string<br/>    common_attributes = optional(list(object({<br/>      name  = string<br/>      value = string<br/>    })), [])<br/>  }))</pre> | <pre>{<br/>  "audit": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "common_attributes": [],<br/>    "content_encoding": "NONE",<br/>    "name": "fleet-audit-datadog",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10<br/>  },<br/>  "results": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "common_attributes": [],<br/>    "content_encoding": "NONE",<br/>    "name": "fleet-osquery-results-datadog",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10<br/>  },<br/>  "status": {<br/>    "buffering_interval": 60,<br/>    "buffering_size": 2,<br/>    "common_attributes": [],<br/>    "content_encoding": "NONE",<br/>    "name": "fleet-osquery-status-datadog",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10<br/>  }<br/>}</pre> | no |
| <a name="input_s3_bucket_config"></a> [s3\_bucket\_config](#input\_s3\_bucket\_config) | Configuration for the S3 bucket used to store failed Datadog delivery attempts | <pre>object({<br/>    name_prefix  = optional(string, "fleet-datadog-failure")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name_prefix": "fleet-datadog-failure"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | Environment variables to configure Fleet to use Datadog logging via Firehose |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | IAM policies required for Fleet to log to Datadog via Firehose |
