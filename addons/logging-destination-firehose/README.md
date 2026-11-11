# Logging Destination: Firehose
This addon provides a Kinesis Firehose logging destination for Fleet.

## S3 Bucket Policy: Deny Non-HTTPS

This module automatically attaches a bucket policy to each S3 bucket (osquery-results, osquery-status, audit) that denies any requests made over plain HTTP. No configuration is required.

## Optional Features

All optional features below default to disabled. Enabling any feature that adds create-only attributes to a Firehose delivery stream (buffering, prefix, SSE) will require the stream to be recreated.

### Firehose Buffering and S3 Prefixes

Set `firehose_buffering_size` and `firehose_buffering_interval` to control how Firehose batches data before writing to S3. Set `firehose_s3_prefix` and `firehose_s3_error_output_prefix` to control the S3 key paths (e.g., time-partitioned paths like `results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/`).

### Firehose Server-Side Encryption

Set `firehose_sse_enabled = true` to encrypt delivery streams with a customer-managed KMS key. Provide `kms_key_arn` to use an existing key, or leave it empty to have the module create one.

### CloudWatch Logging

Set `firehose_cloudwatch_logging_enabled = true` to create CloudWatch log groups for each delivery stream and grant the Firehose service `logs:PutLogEvents` permissions.

### S3 Bucket Keys

Set `s3_bucket_key_enabled = true` to enable S3 bucket keys, which reduce the number of KMS API calls and lower costs.

### S3 Bucket Layout

This module manages three separate S3 buckets — one each for osquery results, osquery status, and audit logs. A single shared bucket option is not currently exposed.

### Variable Naming

New optional variables use a prefix to indicate scope: `firehose_` for Firehose delivery stream settings, `s3_` for S3 bucket settings, and `kms_` for shared KMS key configuration.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.29.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.53.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_stream.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_stream) | resource |
| [aws_iam_policy.firehose-audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.firehose-audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.firehose-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.firehose-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.firehose-audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.firehose-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.firehose-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_kinesis_firehose_delivery_stream.osquery_results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_kinesis_firehose_delivery_stream.osquery_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_kms_alias.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [aws_s3_bucket.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.osquery-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.osquery-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.osquery-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.osquery-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_policy.deny_insecure_transport_audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.deny_insecure_transport_osquery_results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.deny_insecure_transport_osquery_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.osquery-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.osquery-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.osquery-results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.osquery-status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.audit_policy_doc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.deny_insecure_transport_audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.deny_insecure_transport_osquery_results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.deny_insecure_transport_osquery_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_results_policy_doc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_status_policy_doc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_audit_s3_bucket"></a> [audit\_s3\_bucket](#input\_audit\_s3\_bucket) | n/a | <pre>object({<br/>    name         = optional(string, "fleet-audit-archive")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name": "fleet-audit-archive"<br/>}</pre> | no |
| <a name="input_compression_format"></a> [compression\_format](#input\_compression\_format) | n/a | `string` | `"UNCOMPRESSED"` | no |
| <a name="input_firehose_buffering_interval"></a> [firehose\_buffering\_interval](#input\_firehose\_buffering\_interval) | Firehose buffering interval in seconds. Set to null (default) to use the AWS default (60 s). | `number` | `null` | no |
| <a name="input_firehose_buffering_size"></a> [firehose\_buffering\_size](#input\_firehose\_buffering\_size) | Firehose buffering size in MB. Set to null (default) to use the AWS default (4 MB). | `number` | `null` | no |
| <a name="input_firehose_cloudwatch_logging_enabled"></a> [firehose\_cloudwatch\_logging\_enabled](#input\_firehose\_cloudwatch\_logging\_enabled) | Enable CloudWatch logging for Firehose delivery streams. Creates log groups and grants logs:PutLogEvents permissions. | `bool` | `false` | no |
| <a name="input_firehose_s3_error_output_prefix"></a> [firehose\_s3\_error\_output\_prefix](#input\_firehose\_s3\_error\_output\_prefix) | S3 key prefix for Firehose error output. Set to null (default) for no error prefix. | `string` | `null` | no |
| <a name="input_firehose_s3_prefix"></a> [firehose\_s3\_prefix](#input\_firehose\_s3\_prefix) | S3 key prefix for Firehose delivery streams. Set to null (default) for no prefix. | `string` | `null` | no |
| <a name="input_firehose_sse_enabled"></a> [firehose\_sse\_enabled](#input\_firehose\_sse\_enabled) | Enable server-side encryption on Firehose delivery streams with a customer-managed KMS key. | `bool` | `false` | no |
| <a name="input_kms_base_policy"></a> [kms\_base\_policy](#input\_kms\_base\_policy) | Base KMS key policy statements for the auto-created CMK. When null (default), a root-account kms:* statement is used. Only valid when the module creates the CMK (kms\_key\_arn is empty). | <pre>list(object({<br/>    sid    = string<br/>    effect = string<br/>    principals = object({<br/>      type        = string<br/>      identifiers = list(string)<br/>    })<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `null` | no |
| <a name="input_kms_extra_policies"></a> [kms\_extra\_policies](#input\_kms\_extra\_policies) | Extra KMS key policy statements for the auto-created CMK. Only valid when the module creates the CMK (kms\_key\_arn is empty). | `any` | `[]` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of an existing KMS key to use for Firehose SSE and S3 encryption. If not set and a key is needed (firehose\_sse\_enabled or s3\_kms\_encryption\_enabled), a key is created automatically. | `string` | `""` | no |
| <a name="input_osquery_results_s3_bucket"></a> [osquery\_results\_s3\_bucket](#input\_osquery\_results\_s3\_bucket) | n/a | <pre>object({<br/>    name         = optional(string, "fleet-osquery-results-archive")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name": "fleet-osquery-results-archive"<br/>}</pre> | no |
| <a name="input_osquery_status_s3_bucket"></a> [osquery\_status\_s3\_bucket](#input\_osquery\_status\_s3\_bucket) | n/a | <pre>object({<br/>    name         = optional(string, "fleet-osquery-status-archive")<br/>    expires_days = optional(number, 1)<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "name": "fleet-osquery-status-archive"<br/>}</pre> | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | n/a | `string` | `""` | no |
| <a name="input_s3_bucket_key_enabled"></a> [s3\_bucket\_key\_enabled](#input\_s3\_bucket\_key\_enabled) | Enable S3 bucket keys for server-side encryption to reduce KMS API costs. Set to false (default) to leave unchanged. | `bool` | `false` | no |
| <a name="input_s3_kms_encryption_enabled"></a> [s3\_kms\_encryption\_enabled](#input\_s3\_kms\_encryption\_enabled) | Enable S3 server-side encryption with the customer-managed KMS key (same key used for Firehose SSE). When false, S3 uses the AWS-managed S3 key. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | n/a |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | n/a |
| <a name="output_fleet_s3_firehose_audit_config"></a> [fleet\_s3\_firehose\_audit\_config](#output\_fleet\_s3\_firehose\_audit\_config) | S3 bucket details - audit |
| <a name="output_fleet_s3_firehose_osquery_results_config"></a> [fleet\_s3\_firehose\_osquery\_results\_config](#output\_fleet\_s3\_firehose\_osquery\_results\_config) | S3 bucket details - osquery-results |
| <a name="output_fleet_s3_firehose_osquery_status_config"></a> [fleet\_s3\_firehose\_osquery\_status\_config](#output\_fleet\_s3\_firehose\_osquery\_status\_config) | S3 bucket details - osquery-status |
| <a name="output_kms_key_alias"></a> [kms\_key\_alias](#output\_kms\_key\_alias) | Alias of the auto-created KMS key (e.g. "alias/fleet-firehose"). Null when the module does not create the key. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key used for Firehose SSE and S3 encryption. Null when no CMK feature is enabled. |
