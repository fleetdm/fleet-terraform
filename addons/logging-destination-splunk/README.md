# Logging Destination: Splunk

This addon configures AWS Kinesis Firehose to send Fleet's osquery logs to Splunk. It creates:

1. Kinesis Firehose delivery streams for each log type (results, status, and audit)
2. A single S3 bucket for storing all failed delivery attempts
3. IAM roles and policies for the Firehose streams to access the S3 bucket
4. An IAM policy for Fleet to access the Firehose streams

## How to use

```hcl
module "splunk-logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-splunk?depth=1&ref=tf-mod-addon-logging-destination-splunk-v1.0.0"

  s3_bucket_config = {
    name_prefix  = "fleet-splunk-failure"
    expires_days = 5
  }

  log_destinations = {
    results = {
      name                        = "fleet-osquery-results-splunk"
      hec_endpont                 = "https://http-inputs-mydomain.splunkcloud.com:443"
      hec_token                   = "51D4DA16-C61B-4F5F-8EC7-ED4301342A4A"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "results/"
    },
    status = {
      name                        = "fleet-osquery-status-splunk"
      hec_endpont                 = "https://http-inputs-mydomain.splunkcloud.com:443"
      hec_token                   = "51D4DA16-C61B-4F5F-8EC7-ED4301342A4A"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "status/"
    },
    audit = {
      name                        = "fleet-audit-splunk"
      hec_endpont                 = "https://http-inputs-mydomain.splunkcloud.com:443"
      hec_token                   = "51D4DA16-C61B-4F5F-8EC7-ED4301342A4A"
      hec_acknowledgement_timeout = 600
      hec_endpoint_type           = "Raw"
      s3_buffering_size           = 10
      s3_buffering_interval       = 400
      s3_error_output_prefix      = "audit/"
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
      # Uncomment to enable Splunk logging
      module.splunk-logging.fleet_extra_environment_variables
    )
    extra_iam_policies = concat(
      # Uncomment to enable Splunk logging
      module.splunk-logging.fleet_extra_iam_policies,
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
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.25.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.splunk](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_s3_bucket.splunk-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.splunk-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.splunk-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.splunk-failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_iam_policy_document.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_compression_format"></a> [compression\_format](#input\_compression\_format) | Compression format for the Firehose delivery stream | `string` | `"UNCOMPRESSED"` | no |
| <a name="input_iam_policy_name"></a> [iam\_policy\_name](#input\_iam\_policy\_name) | n/a | `string` | `"splunk-firehose-policy"` | no |
| <a name="input_log_destinations"></a> [log\_destinations](#input\_log\_destinations) | A map of configurations for Splunk Firehose delivery streams. | <pre>map(object({<br/>    # hec endpoint/token are logically optional but validated to enforce <br/>    name                        = string<br/>    hec_endpoint                = optional(string)<br/>    hec_token                   = optional(string)<br/>    hec_acknowledgement_timeout = optional(number, 600)<br/>    hec_endpoint_type           = optional(string, "Raw")<br/>    s3_buffering_size           = optional(number, 2)<br/>    s3_buffering_interval       = optional(number, 400)<br/>    s3_error_output_prefix      = optional(string, null)<br/><br/>  }))</pre> | <pre>{<br/>  "audit": {<br/>    "hec_acknowledgement_timeout": 600,<br/>    "hec_endpoint_type": "Raw",<br/>    "name": "fleet-audit-splunk",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "s3_error_output_prefix": "audit/"<br/>  },<br/>  "results": {<br/>    "hec_acknowledgement_timeout": 600,<br/>    "hec_endpoint_type": "Raw",<br/>    "name": "fleet-osquery-results-splunk",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "s3_error_output_prefix": "results/"<br/>  },<br/>  "status": {<br/>    "hec_acknowledgement_timeout": 600,<br/>    "hec_endpoint_type": "Raw",<br/>    "name": "fleet-osquery-status-splunk",<br/>    "s3_buffering_interval": 400,<br/>    "s3_buffering_size": 10,<br/>    "s3_error_output_prefix": "status/"<br/>  }<br/>}</pre> | no |
| <a name="input_s3_bucket_config"></a> [s3\_bucket\_config](#input\_s3\_bucket\_config) | Configuration for the S3 bucket used to store failed Splunk delivery attempts | <pre>object({<br/>    name_prefix  = optional(string, "fleet-splunk-failure")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name_prefix": "fleet-splunk-failure"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | Environment variables to configure Fleet to use Splunk logging via Firehose |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | IAM policies required for Fleet to log to Splunk via Firehose |
| <a name="output_fleet_s3_splunk_failure_config"></a> [fleet\_s3\_splunk\_failure\_config](#output\_fleet\_s3\_splunk\_failure\_config) | S3 bucket details - splunk-failure |
