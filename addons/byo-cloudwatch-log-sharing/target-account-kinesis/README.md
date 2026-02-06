# Fleet CloudWatch Log Group Sharing via Kinesis (Target Account)

This module creates the cross-account CloudWatch Logs destination and a Kinesis Data Stream target.

Because CloudWatch Logs destinations must be created in the same region as the source log group, this module uses two provider aliases:

- `aws.destination`: Region of the Fleet CloudWatch log group (source region).
- `aws.target`: Region for the Kinesis stream (same region or different region).

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
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/target-account-kinesis"

  providers = {
    aws.destination = aws.source_region
    aws.target      = aws.target_region
  }

  source_account_ids = ["111111111111"]

  cloudwatch_destination = {
    name = "fleet-app-logs"
  }

  kinesis = {
    stream_name = "fleet-app-logs"
  }
}

output "fleet_log_sharing_target" {
  value = module.fleet_log_sharing_target
}
```

Then apply the source account module (`../cloudwatch`) using `module.fleet_log_sharing_target.log_destination_arn` and set `destination_type = "kinesis"`.

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
| [aws_iam_role.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_stream.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_stream) | resource |
| [aws_caller_identity.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_caller_identity.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.destination_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_region.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cloudwatch_destination"></a> [cloudwatch\_destination](#input\_cloudwatch\_destination) | CloudWatch Logs destination settings in the source log-group region. | <pre>object({<br/>    name      = optional(string, "fleet-log-sharing-destination")<br/>    role_name = optional(string, "fleet-log-sharing-destination-role")<br/>  })</pre> | `{}` | no |
| <a name="input_destination_policy_source_organization_id"></a> [destination\_policy\_source\_organization\_id](#input\_destination\_policy\_source\_organization\_id) | Optional AWS Organization ID allowed to subscribe to this destination. | `string` | `""` | no |
| <a name="input_kinesis"></a> [kinesis](#input\_kinesis) | Kinesis stream settings used as the CloudWatch Logs destination target. | <pre>object({<br/>    stream_name      = string<br/>    stream_mode      = optional(string, "ON_DEMAND")<br/>    shard_count      = optional(number, 1)<br/>    retention_period = optional(number, 24)<br/>  })</pre> | n/a | yes |
| <a name="input_source_account_ids"></a> [source\_account\_ids](#input\_source\_account\_ids) | AWS account IDs allowed to create subscription filters to this destination. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to created resources that support tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_destination_account_id"></a> [destination\_account\_id](#output\_destination\_account\_id) | AWS account ID where the CloudWatch Logs destination exists. |
| <a name="output_destination_region"></a> [destination\_region](#output\_destination\_region) | Region where the CloudWatch Logs destination was created. This must match the source log group region. |
| <a name="output_destination_role_arn"></a> [destination\_role\_arn](#output\_destination\_role\_arn) | IAM role ARN assumed by CloudWatch Logs to write records into Kinesis. |
| <a name="output_kinesis_region"></a> [kinesis\_region](#output\_kinesis\_region) | Region where the Kinesis stream was created. |
| <a name="output_kinesis_stream_arn"></a> [kinesis\_stream\_arn](#output\_kinesis\_stream\_arn) | Kinesis stream ARN used as CloudWatch Logs destination target. |
| <a name="output_kinesis_stream_name"></a> [kinesis\_stream\_name](#output\_kinesis\_stream\_name) | Kinesis stream name used as CloudWatch Logs destination target. |
| <a name="output_log_destination_arn"></a> [log\_destination\_arn](#output\_log\_destination\_arn) | CloudWatch Logs destination ARN to use from the source account module. |
| <a name="output_log_destination_name"></a> [log\_destination\_name](#output\_log\_destination\_name) | CloudWatch Logs destination name. |
