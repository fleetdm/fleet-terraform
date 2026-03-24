# Osquery Carve Bucket Addon
This addon provides a S3 bucket for Osquery Carve results.

## KMS considerations

If `osquery_carve_s3_bucket.kms.create_kms_key = true`, this module now creates the KMS key first and manages the custom key policy through a separate attachment resource. If `fleet_role_name` is omitted, the module still creates the key but leaves the default KMS key policy in place and does not attach a custom policy.

When a module-created customer-managed key must trust the Fleet IAM role, Terraform needs to resolve that role through `data.aws_iam_role` in order to build the KMS key policy. Because that data source cannot read a role that is being created in the same apply, this is a technical limitation that requires a two-stage apply:

1. Apply once without `osquery_carve_s3_bucket.kms.fleet_role_name` so the Fleet IAM role and the KMS key are created.
2. Set `osquery_carve_s3_bucket.kms.fleet_role_name` to the existing Fleet role name and apply again so the module can resolve the role ARN and attach the KMS key policy.

The IAM policy exported by this addon is intentionally S3-only. KMS authorization is handled in the KMS key policy for module-created keys. If `osquery_carve_s3_bucket.kms.kms_key_arn` is set, this module does not manage the referenced key policy and does not export a generic KMS IAM policy for it.

When bringing your own KMS key, it is your responsibility to ensure that key policy and any separately managed IAM permissions allow the Fleet role to perform the required KMS actions for S3 object encryption and decryption.

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
| [aws_kms_key_policy.osquery_carve](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [aws_s3_bucket.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.osquery_carve_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_role.osquery_carve_fleet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |
| [aws_kms_key.osquery_carve_provided](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_osquery_carve_s3_bucket"></a> [osquery\_carve\_s3\_bucket](#input\_osquery\_carve\_s3\_bucket) | Configuration for the osquery carve S3 bucket, including optional customer-managed KMS settings. | <pre>object({<br/>    name         = optional(string, "fleet-osquery-results-archive")<br/>    expires_days = optional(number, 1)<br/>    kms = optional(object({<br/>      kms_key_arn    = optional(string, null)<br/>      create_kms_key = optional(bool, false)<br/>      kms_alias      = optional(string, "osquery-carve")<br/>      kms_base_policy = optional(list(object({<br/>        sid    = string<br/>        effect = string<br/>        principals = object({<br/>          type        = string<br/>          identifiers = list(string)<br/>        })<br/>        actions   = list(string)<br/>        resources = list(string)<br/>        conditions = optional(list(object({<br/>          test     = string<br/>          variable = string<br/>          values   = list(string)<br/>        })), [])<br/>      })), null)<br/>      extra_kms_policies = optional(list(any), [])<br/>      fleet_role_name    = optional(string, null)<br/>      }), {<br/>      kms_key_arn        = null<br/>      create_kms_key     = false<br/>      kms_alias          = "osquery-carve"<br/>      kms_base_policy    = null<br/>      extra_kms_policies = []<br/>      fleet_role_name    = null<br/>    })<br/>  })</pre> | <pre>{<br/>  "expires_days": 1,<br/>  "kms": {<br/>    "create_kms_key": false,<br/>    "extra_kms_policies": [],<br/>    "fleet_role_name": null,<br/>    "kms_alias": "osquery-carve",<br/>    "kms_base_policy": null,<br/>    "kms_key_arn": null<br/>  },<br/>  "name": "fleet-osquery-results-archive"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | n/a |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | IAM policies required for Fleet to access the osquery carve S3 bucket. |
