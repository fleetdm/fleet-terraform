# Fleet CloudWatch Log Group Sharing (Source Account)

## Usage

Use this module in the source Fleet account (and in the same region as the Fleet CloudWatch log group).

### Firehose destination (default)

```hcl
module "fleet_log_sharing" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/cloudwatch"

  subscription = {
    log_group_name  = module.fleet.byo-vpc.byo-db.byo-ecs.logging_config["awslogs-group"]
    destination_arn = "arn:aws:logs:us-east-2:222222222222:destination:fleet-app-logs-firehose"
    # destination_type defaults to "firehose"
    filter_pattern = ""
  }
}
```

### Kinesis destination

```hcl
module "fleet_log_sharing" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/cloudwatch"

  subscription = {
    log_group_name       = module.fleet.byo-vpc.byo-db.byo-ecs.logging_config["awslogs-group"]
    destination_arn      = "arn:aws:logs:us-east-2:222222222222:destination:fleet-app-logs-kinesis"
    destination_type     = "kinesis"
    kinesis_distribution = "ByLogStream"
    filter_pattern       = ""
  }
}
```

`subscription.destination_arn` is usually provided out-of-band by the organization that runs the target-account module in their environment.

No Fleet environment variable changes are required. This module configures the CloudWatch Logs subscription directly on the Fleet log group.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.29.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.29.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_subscription_filter.fleet_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_subscription_filter) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_subscription"></a> [subscription](#input\_subscription) | CloudWatch Logs subscription configuration for sharing a source log group to a cross-account destination. | <pre>object({<br/>    log_group_name       = string<br/>    destination_arn      = string<br/>    filter_name          = optional(string, "fleet-log-sharing")<br/>    filter_pattern       = optional(string, "")<br/>    destination_type     = optional(string, "firehose")<br/>    kinesis_distribution = optional(string, "ByLogStream")<br/>  })</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_subscription_filter_destination_arn"></a> [subscription\_filter\_destination\_arn](#output\_subscription\_filter\_destination\_arn) | CloudWatch Logs destination ARN used by the subscription filter. |
| <a name="output_subscription_filter_log_group_name"></a> [subscription\_filter\_log\_group\_name](#output\_subscription\_filter\_log\_group\_name) | CloudWatch Logs log group name where the subscription filter is configured. |
| <a name="output_subscription_filter_name"></a> [subscription\_filter\_name](#output\_subscription\_filter\_name) | Created CloudWatch Logs subscription filter name. |
