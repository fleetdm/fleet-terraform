# Fleet CloudWatch Log Group Sharing via Firehose (Target Account)

This module creates the cross-account CloudWatch Logs destination and a Firehose delivery stream target.

CloudWatch Logs subscription payloads are already gzip-compressed. This module defaults Firehose `compression_format` to `UNCOMPRESSED` to avoid double-compression.

Because CloudWatch Logs destinations must be created in the same region as the source log group, this module uses two provider aliases:

- `aws.destination`: Region of the Fleet CloudWatch log group (source region).
- `aws.target`: Region for the Firehose stream and S3 bucket (same region or different region).

## Usage

```hcl
provider "aws" {
  alias  = "source_region"
  region = "us-east-2"
}

provider "aws" {
  alias  = "target_region"
  region = "us-west-2"
}

module "fleet_log_sharing_target" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/target-account-firehose"

  providers = {
    aws.destination = aws.source_region
    aws.target      = aws.target_region
  }

  source_account_ids = ["111111111111"]

  cloudwatch_destination = {
    name = "fleet-app-logs-firehose"
  }

  firehose = {
    delivery_stream_name = "fleet-app-logs-firehose"
    # Optional override; default is UNCOMPRESSED.
    compression_format   = "UNCOMPRESSED"
  }

  s3 = {
    bucket_name = "fleet-app-logs-firehose-example"
  }
}

output "fleet_log_sharing_target" {
  value = module.fleet_log_sharing_target
}
```

Then apply the source account module (`../cloudwatch`) using `module.fleet_log_sharing_target.log_destination.arn` (default `destination_type` is `firehose`).

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.29.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.29.0 |
| <a name="provider_aws.destination"></a> [aws.destination](#provider\_aws.destination) | >= 5.29.0 |
| <a name="provider_aws.target"></a> [aws.target](#provider\_aws.target) | >= 5.29.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_destination.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_destination) | resource |
| [aws_cloudwatch_log_destination_policy.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_destination_policy) | resource |
| [aws_iam_policy.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_s3_bucket.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_public_access_block.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_caller_identity.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_caller_identity.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.destination_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_region.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cloudwatch_destination"></a> [cloudwatch\_destination](#input\_cloudwatch\_destination) | CloudWatch Logs destination settings in the source log-group region. | <pre>object({<br/>    name      = optional(string, "fleet-log-sharing-firehose-destination")<br/>    role_name = optional(string, "fleet-log-sharing-firehose-destination-role")<br/>  })</pre> | `{}` | no |
| <a name="input_destination_policy_source_organization_id"></a> [destination\_policy\_source\_organization\_id](#input\_destination\_policy\_source\_organization\_id) | Optional AWS Organization ID allowed to subscribe to this destination. | `string` | `""` | no |
| <a name="input_firehose"></a> [firehose](#input\_firehose) | Firehose delivery stream settings used as the CloudWatch Logs destination target. CloudWatch Logs subscription payloads are already gzip-compressed, so UNCOMPRESSED is the default to avoid double compression. | <pre>object({<br/>    delivery_stream_name = string<br/>    role_name            = optional(string, "fleet-log-sharing-firehose-delivery-role")<br/>    buffering_size       = optional(number, 5)<br/>    buffering_interval   = optional(number, 300)<br/>    compression_format   = optional(string, "UNCOMPRESSED")<br/>    s3_prefix            = optional(string, "fleet-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/")<br/>    s3_error_prefix      = optional(string, "fleet-logs-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/")<br/>  })</pre> | n/a | yes |
| <a name="input_s3"></a> [s3](#input\_s3) | S3 configuration for Firehose delivered logs. | <pre>object({<br/>    bucket_name   = string<br/>    force_destroy = optional(bool, false)<br/>  })</pre> | n/a | yes |
| <a name="input_source_account_ids"></a> [source\_account\_ids](#input\_source\_account\_ids) | AWS account IDs allowed to create subscription filters to this destination. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to created resources that support tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_firehose"></a> [firehose](#output\_firehose) | Firehose destination details. |
| <a name="output_log_destination"></a> [log\_destination](#output\_log\_destination) | CloudWatch Logs destination details to share with the source-account team. |
| <a name="output_s3_bucket"></a> [s3\_bucket](#output\_s3\_bucket) | S3 bucket details used as the Firehose destination. |
