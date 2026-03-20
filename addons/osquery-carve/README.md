# Osquery Carve Bucket Addon
This addon provides a S3 bucket for Osquery Carve results.

## KMS considerations

If `osquery_carve_s3_bucket.kms.kms_key_arn` is set, this module can grant Fleet IAM permissions to use that key through the IAM policy it exports, but it does not manage the policy on the referenced KMS key itself.

When bringing your own KMS key, it is your responsibility to ensure that key policy and any related grants allow the Fleet role to perform the required KMS actions for S3 object encryption and decryption.

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.37.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_kms_alias.osquery_carve](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.osquery_carve](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_carve_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_kms_key.osquery_carve_provided](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_osquery_carve_s3_bucket"></a> [osquery\_carve\_s3\_bucket](#input\_osquery\_carve\_s3\_bucket) | Configuration for the osquery carve S3 bucket, including optional customer-managed KMS settings. | <pre>object({<br/>    name         = optional(string, "fleet-osquery-results-archive")<br/>    expires_days = optional(number, 1)<br/>    kms = optional(object({<br/>      kms_key_arn    = optional(string, null)<br/>      create_kms_key = optional(bool, false)<br/>      kms_alias      = optional(string, "osquery-carve")<br/>      kms_base_policy = optional(list(object({<br/>        sid    = string<br/>        effect = string<br/>        principals = object({<br/>          type        = string<br/>          identifiers = list(string)<br/>        })<br/>        actions   = list(string)<br/>        resources = list(string)<br/>        conditions = optional(list(object({<br/>          test     = string<br/>          variable = string<br/>          values   = list(string)<br/>        })), [])<br/>      })), null)<br/>      extra_kms_policies = optional(list(any), [])<br/>      fleet_role_arn     = optional(string, null)<br/>      }), {<br/>      kms_key_arn        = null<br/>      create_kms_key     = false<br/>      kms_alias          = "osquery-carve"<br/>      kms_base_policy    = null<br/>      extra_kms_policies = []<br/>      fleet_role_arn     = null<br/>    })<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "kms": {<br/>    "create_kms_key": false,<br/>    "extra_kms_policies": [],<br/>    "fleet_role_arn": null,<br/>    "kms_alias": "osquery-carve",<br/>    "kms_base_policy": null,<br/>    "kms_key_arn": null<br/>  },<br/>  "name": "fleet-osquery-results-archive"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | n/a |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | n/a |
