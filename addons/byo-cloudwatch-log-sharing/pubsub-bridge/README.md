# Fleet CloudWatch Logs to GCP Pub/Sub Bridge

This module creates an AWS Lambda subscription target for a Fleet CloudWatch log group and forwards log events to a GCP Pub/Sub topic.

The Lambda function reads Google service account credentials from an existing AWS Secrets Manager secret.
Deploy this module in the same AWS region as the Fleet CloudWatch log group.
The bridge Lambda is implemented in Go and compiled during Terraform apply.
Publishing uses the official `cloud.google.com/go/pubsub/v2` client library.
The Terraform execution environment must include a working `go` toolchain.

## Usage

```hcl
provider "aws" {
  region = "us-east-2"
}

variable "gcp_pubsub_service_account_credentials_json" {
  description = "Google service-account credentials JSON shared by the customer (for example from target-account-gcp publisher_credentials_json)."
  type        = string
  sensitive   = true
}

resource "aws_secretsmanager_secret" "gcp_pubsub_credentials" {
  name = "fleet/gcp/pubsub/service-account"
}

resource "aws_secretsmanager_secret_version" "gcp_pubsub_credentials" {
  secret_id = aws_secretsmanager_secret.gcp_pubsub_credentials.id
  secret_string = jsonencode({
    service_account_json = var.gcp_pubsub_service_account_credentials_json
  })
}

module "fleet_pubsub_bridge" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/pubsub-bridge?depth=1&ref=tf-mod-addon-byo-cloudwatch-log-sharing-v1.0.0"

  subscription = {
    log_group_name = module.fleet.byo-vpc.byo-db.byo-ecs.logging_config["awslogs-group"]
    filter_pattern = ""
  }

  gcp_pubsub = {
    project_id             = "customer-observability-prod"
    topic_id               = "fleet-logs"
    credentials_secret_arn = aws_secretsmanager_secret.gcp_pubsub_credentials.arn
  }

  lambda = {
    function_name = "fleet-cloudwatch-pubsub-bridge"
    role_name     = "fleet-cloudwatch-pubsub-bridge-role"
    policy_name   = "fleet-cloudwatch-pubsub-bridge-policy"
    timeout       = 60
    memory_size   = 256
    batch_size    = 1000
  }

  dlq = {
    enabled                      = true
    queue_name                   = "fleet-cloudwatch-pubsub-bridge-dlq"
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }

  alerting = {
    enabled                        = true
    sns_topic_arns                 = ["arn:aws:sns:us-east-2:111111111111:fleet-ops-alerts"]
    period_seconds                 = 300
    evaluation_periods             = 1
    datapoints_to_alarm            = 1
    lambda_errors_threshold        = 1
    dlq_visible_messages_threshold = 1
    enable_ok_notifications        = true
  }

  replayer = {
    enabled                            = true
    function_name                      = "fleet-cloudwatch-pubsub-bridge-replayer"
    batch_size                         = 10
    maximum_batching_window_in_seconds = 5
    maximum_concurrency                = 2
  }
}

output "fleet_pubsub_bridge" {
  value = module.fleet_pubsub_bridge
}
```

The referenced secret should contain either:
- A Google service-account key JSON document directly.
- A JSON object with a `service_account_json` field that contains the service-account key JSON.

This module uses CloudWatch alarms for notifications so alerts fire on state transitions instead of per-failed event, which avoids high-volume SNS spam during sustained failures.

A built-in SQS replayer Lambda is enabled by default and re-drives failed async events from the DLQ back to the main bridge Lambda with partial-batch failure handling.

## Reprocessing Options

1. Built-in automatic replay:
Use the module's default `replayer` settings to continuously re-drive failed events from DLQ.
2. Manual/batched replay:
Drain DLQ messages to S3 for analysis, then replay selected batches during controlled windows.
3. Scheduled replay workflow:
Use EventBridge Scheduler or Step Functions to periodically replay aged DLQ messages with rate limits and stop conditions.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.4.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.29.0 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.2.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.4.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.29.0 |
| <a name="provider_null"></a> [null](#provider\_null) | >= 3.2.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_subscription_filter.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_subscription_filter) | resource |
| [aws_cloudwatch_metric_alarm.dlq_visible_messages](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.lambda_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.replayer_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_policy.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_basic_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.replayer_lambda_basic_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_event_source_mapping.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping) | resource |
| [aws_lambda_function.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_permission.allow_cloudwatch_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_sqs_queue.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [null_resource.bridge_build](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.replayer_build](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [archive_file.bridge](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.replayer](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alerting"></a> [alerting](#input\_alerting) | CloudWatch alarm and SNS notification settings for bridge failures. | <pre>object({<br/>    enabled                        = optional(bool, true)<br/>    sns_topic_arns                 = optional(list(string), [])<br/>    enable_ok_notifications        = optional(bool, true)<br/>    period_seconds                 = optional(number, 300)<br/>    evaluation_periods             = optional(number, 1)<br/>    datapoints_to_alarm            = optional(number, 1)<br/>    lambda_errors_threshold        = optional(number, 1)<br/>    dlq_visible_messages_threshold = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_dlq"></a> [dlq](#input\_dlq) | Asynchronous Lambda failure handling via SQS dead-letter queue. | <pre>object({<br/>    enabled                      = optional(bool, true)<br/>    queue_name                   = optional(string)<br/>    maximum_retry_attempts       = optional(number, 2)<br/>    maximum_event_age_in_seconds = optional(number, 3600)<br/>    message_retention_seconds    = optional(number, 1209600)<br/>    visibility_timeout_seconds   = optional(number, 60)<br/>    sqs_managed_sse_enabled      = optional(bool, true)<br/>    kms_master_key_id            = optional(string, "")<br/>  })</pre> | `{}` | no |
| <a name="input_gcp_pubsub"></a> [gcp\_pubsub](#input\_gcp\_pubsub) | GCP Pub/Sub settings and credentials secret reference for cloud.google.com/go/pubsub/v2. The secret must contain a Google service-account key JSON, or a JSON object with a service\_account\_json field containing that key JSON. | <pre>object({<br/>    project_id             = string<br/>    topic_id               = string<br/>    credentials_secret_arn = string<br/>    secret_kms_key_arn     = optional(string, "")<br/>  })</pre> | n/a | yes |
| <a name="input_lambda"></a> [lambda](#input\_lambda) | Go-based Lambda bridge configuration. | <pre>object({<br/>    function_name                  = optional(string, "fleet-cloudwatch-pubsub-bridge")<br/>    role_name                      = optional(string, "fleet-cloudwatch-pubsub-bridge-role")<br/>    policy_name                    = optional(string)<br/>    runtime                        = optional(string, "provided.al2")<br/>    architecture                   = optional(string, "x86_64")<br/>    memory_size                    = optional(number, 256)<br/>    timeout                        = optional(number, 60)<br/>    log_retention_in_days          = optional(number, 30)<br/>    reserved_concurrent_executions = optional(number, -1)<br/>    batch_size                     = optional(number, 1000)<br/>  })</pre> | `{}` | no |
| <a name="input_replayer"></a> [replayer](#input\_replayer) | SQS DLQ replayer settings. Replays failed bridge events back to the main bridge Lambda. | <pre>object({<br/>    enabled                            = optional(bool, true)<br/>    function_name                      = optional(string)<br/>    role_name                          = optional(string)<br/>    policy_name                        = optional(string)<br/>    runtime                            = optional(string)<br/>    architecture                       = optional(string)<br/>    memory_size                        = optional(number, 256)<br/>    timeout                            = optional(number, 60)<br/>    log_retention_in_days              = optional(number, 30)<br/>    reserved_concurrent_executions     = optional(number, -1)<br/>    batch_size                         = optional(number, 10)<br/>    maximum_batching_window_in_seconds = optional(number, 5)<br/>    maximum_concurrency                = optional(number, 2)<br/>  })</pre> | `{}` | no |
| <a name="input_subscription"></a> [subscription](#input\_subscription) | CloudWatch Logs subscription settings for sending Fleet log events to the Pub/Sub bridge Lambda. | <pre>object({<br/>    log_group_name = string<br/>    log_group_arn  = optional(string)<br/>    filter_name    = optional(string, "fleet-log-pubsub-bridge")<br/>    filter_pattern = optional(string, "")<br/>  })</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to created resources that support tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alerting"></a> [alerting](#output\_alerting) | CloudWatch alarm and notification resources for bridge health. |
| <a name="output_dlq"></a> [dlq](#output\_dlq) | Dead-letter queue configuration and resource details. |
| <a name="output_lambda"></a> [lambda](#output\_lambda) | Lambda bridge details. |
| <a name="output_pubsub"></a> [pubsub](#output\_pubsub) | Configured GCP Pub/Sub destination details. |
| <a name="output_replayer"></a> [replayer](#output\_replayer) | DLQ replayer Lambda and event source mapping details. |
| <a name="output_subscription_filter"></a> [subscription\_filter](#output\_subscription\_filter) | CloudWatch Logs subscription filter details. |

<!-- BEGIN_TF_DOCS -->
# Fleet CloudWatch Logs to GCP Pub/Sub Bridge

This module creates an AWS Lambda subscription target for a Fleet CloudWatch log group and forwards log events to a GCP Pub/Sub topic.

The Lambda function reads Google service account credentials from an existing AWS Secrets Manager secret.
Deploy this module in the same AWS region as the Fleet CloudWatch log group.
The bridge Lambda is implemented in Go and compiled during Terraform apply.
Publishing uses the official `cloud.google.com/go/pubsub/v2` client library.
The Terraform execution environment must include a working `go` toolchain.

## Usage

```hcl
provider "aws" {
  region = "us-east-2"
}

variable "gcp_pubsub_service_account_credentials_json" {
  description = "Google service-account credentials JSON shared by the customer (for example from target-account-gcp publisher_credentials_json)."
  type        = string
  sensitive   = true
}

resource "aws_secretsmanager_secret" "gcp_pubsub_credentials" {
  name = "fleet/gcp/pubsub/service-account"
}

resource "aws_secretsmanager_secret_version" "gcp_pubsub_credentials" {
  secret_id = aws_secretsmanager_secret.gcp_pubsub_credentials.id
  secret_string = jsonencode({
    service_account_json = var.gcp_pubsub_service_account_credentials_json
  })
}

module "fleet_pubsub_bridge" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/pubsub-bridge?depth=1&ref=tf-mod-addon-byo-cloudwatch-log-sharing-v1.0.0"

  subscription = {
    log_group_name = module.fleet.byo-vpc.byo-db.byo-ecs.logging_config["awslogs-group"]
    filter_pattern = ""
  }

  gcp_pubsub = {
    project_id             = "customer-observability-prod"
    topic_id               = "fleet-logs"
    credentials_secret_arn = aws_secretsmanager_secret.gcp_pubsub_credentials.arn
  }

  lambda = {
    function_name = "fleet-cloudwatch-pubsub-bridge"
    role_name     = "fleet-cloudwatch-pubsub-bridge-role"
    policy_name   = "fleet-cloudwatch-pubsub-bridge-policy"
    timeout       = 60
    memory_size   = 256
    batch_size    = 1000
  }

  dlq = {
    enabled                      = true
    queue_name                   = "fleet-cloudwatch-pubsub-bridge-dlq"
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }

  alerting = {
    enabled                        = true
    sns_topic_arns                 = ["arn:aws:sns:us-east-2:111111111111:fleet-ops-alerts"]
    period_seconds                 = 300
    evaluation_periods             = 1
    datapoints_to_alarm            = 1
    lambda_errors_threshold        = 1
    dlq_visible_messages_threshold = 1
    enable_ok_notifications        = true
  }

  replayer = {
    enabled                            = true
    function_name                      = "fleet-cloudwatch-pubsub-bridge-replayer"
    batch_size                         = 10
    maximum_batching_window_in_seconds = 5
    maximum_concurrency                = 2
  }
}

output "fleet_pubsub_bridge" {
  value = module.fleet_pubsub_bridge
}
```

The referenced secret should contain either:
- A Google service-account key JSON document directly.
- A JSON object with a `service_account_json` field that contains the service-account key JSON.

This module uses CloudWatch alarms for notifications so alerts fire on state transitions instead of per-failed event, which avoids high-volume SNS spam during sustained failures.

A built-in SQS replayer Lambda is enabled by default and re-drives failed async events from the DLQ back to the main bridge Lambda with partial-batch failure handling.

## Reprocessing Options

1. Built-in automatic replay:
Use the module's default `replayer` settings to continuously re-drive failed events from DLQ.
2. Manual/batched replay:
Drain DLQ messages to S3 for analysis, then replay selected batches during controlled windows.
3. Scheduled replay workflow:
Use EventBridge Scheduler or Step Functions to periodically replay aged DLQ messages with rate limits and stop conditions.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.4.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.29.0 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.2.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.4.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.29.0 |
| <a name="provider_null"></a> [null](#provider\_null) | >= 3.2.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_subscription_filter.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_subscription_filter) | resource |
| [aws_cloudwatch_metric_alarm.dlq_visible_messages](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.lambda_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.replayer_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_policy.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_basic_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.replayer_lambda_basic_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_event_source_mapping.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping) | resource |
| [aws_lambda_function.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_permission.allow_cloudwatch_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_sqs_queue.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [null_resource.bridge_build](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.replayer_build](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [archive_file.bridge](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.replayer](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.replayer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alerting"></a> [alerting](#input\_alerting) | CloudWatch alarm and SNS notification settings for bridge failures. | <pre>object({<br/>    enabled                        = optional(bool, true)<br/>    sns_topic_arns                 = optional(list(string), [])<br/>    enable_ok_notifications        = optional(bool, true)<br/>    period_seconds                 = optional(number, 300)<br/>    evaluation_periods             = optional(number, 1)<br/>    datapoints_to_alarm            = optional(number, 1)<br/>    lambda_errors_threshold        = optional(number, 1)<br/>    dlq_visible_messages_threshold = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_dlq"></a> [dlq](#input\_dlq) | Asynchronous Lambda failure handling via SQS dead-letter queue. | <pre>object({<br/>    enabled                      = optional(bool, true)<br/>    queue_name                   = optional(string)<br/>    maximum_retry_attempts       = optional(number, 2)<br/>    maximum_event_age_in_seconds = optional(number, 3600)<br/>    message_retention_seconds    = optional(number, 1209600)<br/>    visibility_timeout_seconds   = optional(number, 60)<br/>    sqs_managed_sse_enabled      = optional(bool, true)<br/>    kms_master_key_id            = optional(string, "")<br/>  })</pre> | `{}` | no |
| <a name="input_gcp_pubsub"></a> [gcp\_pubsub](#input\_gcp\_pubsub) | GCP Pub/Sub settings and credentials secret reference for cloud.google.com/go/pubsub/v2. The secret must contain a Google service-account key JSON, or a JSON object with a service\_account\_json field containing that key JSON. | <pre>object({<br/>    project_id             = string<br/>    topic_id               = string<br/>    credentials_secret_arn = string<br/>    secret_kms_key_arn     = optional(string, "")<br/>  })</pre> | n/a | yes |
| <a name="input_lambda"></a> [lambda](#input\_lambda) | Go-based Lambda bridge configuration. | <pre>object({<br/>    function_name                  = optional(string, "fleet-cloudwatch-pubsub-bridge")<br/>    role_name                      = optional(string, "fleet-cloudwatch-pubsub-bridge-role")<br/>    policy_name                    = optional(string)<br/>    runtime                        = optional(string, "provided.al2")<br/>    architecture                   = optional(string, "x86_64")<br/>    memory_size                    = optional(number, 256)<br/>    timeout                        = optional(number, 60)<br/>    log_retention_in_days          = optional(number, 30)<br/>    reserved_concurrent_executions = optional(number, -1)<br/>    batch_size                     = optional(number, 1000)<br/>  })</pre> | `{}` | no |
| <a name="input_replayer"></a> [replayer](#input\_replayer) | SQS DLQ replayer settings. Replays failed bridge events back to the main bridge Lambda. | <pre>object({<br/>    enabled                            = optional(bool, true)<br/>    function_name                      = optional(string)<br/>    role_name                          = optional(string)<br/>    policy_name                        = optional(string)<br/>    runtime                            = optional(string)<br/>    architecture                       = optional(string)<br/>    memory_size                        = optional(number, 256)<br/>    timeout                            = optional(number, 60)<br/>    log_retention_in_days              = optional(number, 30)<br/>    reserved_concurrent_executions     = optional(number, -1)<br/>    batch_size                         = optional(number, 10)<br/>    maximum_batching_window_in_seconds = optional(number, 5)<br/>    maximum_concurrency                = optional(number, 2)<br/>  })</pre> | `{}` | no |
| <a name="input_subscription"></a> [subscription](#input\_subscription) | CloudWatch Logs subscription settings for sending Fleet log events to the Pub/Sub bridge Lambda. | <pre>object({<br/>    log_group_name = string<br/>    log_group_arn  = optional(string)<br/>    filter_name    = optional(string, "fleet-log-pubsub-bridge")<br/>    filter_pattern = optional(string, "")<br/>  })</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to created resources that support tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alerting"></a> [alerting](#output\_alerting) | CloudWatch alarm and notification resources for bridge health. |
| <a name="output_dlq"></a> [dlq](#output\_dlq) | Dead-letter queue configuration and resource details. |
| <a name="output_lambda"></a> [lambda](#output\_lambda) | Lambda bridge details. |
| <a name="output_pubsub"></a> [pubsub](#output\_pubsub) | Configured GCP Pub/Sub destination details. |
| <a name="output_replayer"></a> [replayer](#output\_replayer) | DLQ replayer Lambda and event source mapping details. |
| <a name="output_subscription_filter"></a> [subscription\_filter](#output\_subscription\_filter) | CloudWatch Logs subscription filter details. |
<!-- END_TF_DOCS -->
