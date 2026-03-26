# ALB Logging Addon
This addon creates an S3 bucket for ALB access logs with in-place SSE-KMS re-encryption via Lambda. ALB access logging requires SSE-S3 (AES256), so objects are written with SSE-S3 and immediately re-encrypted to SSE-KMS using a customer-managed KMS key. The same module-managed CMK also encrypts the Lambda functions and their CloudWatch log groups.

## How it works

1. **ALB writes** log objects to the S3 bucket using SSE-S3 (the only encryption ALB supports).
2. **Event-driven Lambda** triggers on `s3:ObjectCreated:Put` and re-encrypts each object in-place to SSE-KMS via `CopyObject`. The Lambda's `CopyObject` emits `s3:ObjectCreated:Copy` which does not re-trigger the notification (loop prevention).
3. **Daily sweep Lambda** runs via EventBridge and scans the last 2 days of ALB log prefixes. If any SSE-S3 objects are found (missed by the event-driven Lambda), it generates a CSV manifest and submits an S3 Batch Operations `S3PutObjectCopy` job to re-encrypt them.

Optionally creates Athena resources for querying the logs.

# Example Configuration

This assumes your fleet module is `main` and is configured with its default documentation.

See https://github.com/fleetdm/fleet/blob/main/terraform/example/main.tf for details.

```
module "main" {
  source          = "github.com/fleetdm/fleet-terraform/?ref=main"
  certificate_arn = module.acm.acm_certificate_arn
  vpc = {
    name = random_pet.main.id
  }
  fleet_config = {
    extra_environment_variables = module.firehose-logging.fleet_extra_environment_variables
    extra_iam_policies          = module.firehose-logging.fleet_extra_iam_policies
  }
  alb_config = {
    access_logs = {
      bucket  = module.logging_alb.log_s3_bucket_id
      prefix  = "fleet"
      enabled = true
    }
  }
}

module "logging_alb" {
  source        = "github.com/fleetdm/fleet-terraform//addons/logging-alb?ref=main"
  prefix        = "fleet"
  enable_athena = true
}
```

# Additional Information

Once this terraform is applied, the Athena table will need to be created.  See https://docs.aws.amazon.com/athena/latest/ug/application-load-balancer-logs.html for help with creating the table.

For this implementation, the S3 pattern for the `CREATE TABLE` query should look like this:

```
s3://your-alb-logs-bucket/<PREFIX>/AWSLogs/<ACCOUNT-ID>/elasticloadbalancing/<REGION>/
```

## Migration from previous versions

If upgrading from a previous version that used a separate archive bucket, use the provided script to re-encrypt existing SSE-S3 objects in-place. The script uses S3 Batch Operations with `S3PutObjectCopy` to re-encrypt objects at scale.

1. Apply Terraform so the new Lambda functions and Batch Operations IAM role are in place.
2. Run the migration script to re-encrypt existing objects:

```
./scripts/start-batch-replication-migration.sh \
  --source-bucket fleet-alb-logs
```

The script auto-detects the KMS key by deriving a prefix from the bucket name (stripping the `-alb-logs` suffix) and looking up a KMS alias matching `alias/<prefix>-logs`. Use `--kms-key-arn` to specify the key explicitly. Use `--batch-role-arn` to pass the Terraform-managed Batch Operations role ARN.

3. Wait for the batch job to finish and validate that objects are now SSE-KMS encrypted.
4. Optionally clean up the script-created IAM role:

```
./scripts/start-batch-replication-migration.sh \
  --cleanup-role \
  --source-bucket fleet-alb-logs
```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | 2.7.1 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.37.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_athena-s3-bucket"></a> [athena-s3-bucket](#module\_athena-s3-bucket) | terraform-aws-modules/s3-bucket/aws | 5.0.0 |
| <a name="module_s3_bucket_for_logs"></a> [s3\_bucket\_for\_logs](#module\_s3\_bucket\_for\_logs) | terraform-aws-modules/s3-bucket/aws | 5.0.0 |

## Resources

| Name | Type |
|------|------|
| [aws_athena_database.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_database) | resource |
| [aws_athena_workgroup.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_workgroup) | resource |
| [aws_cloudwatch_event_rule.sweep_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.sweep_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.lambda_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.lambda_sweep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_glue_catalog_table.partitioned_alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_iam_role.batch_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lambda_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lambda_sweep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.batch_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_sweep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.logs_alias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_lambda_function.reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function.sweep_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.eventbridge_invoke_sweep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.s3_invoke_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket_notification.reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [archive_file.lambda_reencrypt](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.lambda_sweep](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.batch_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.batch_reencrypt_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_reencrypt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_reencrypt_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_sweep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda_sweep_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_athena_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_log_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alt_path_prefix"></a> [alt\_path\_prefix](#input\_alt\_path\_prefix) | Used if the prefix inside of the s3 bucket doesn't match the name of the bucket prefix | `string` | `null` | no |
| <a name="input_enable_athena"></a> [enable\_athena](#input\_enable\_athena) | n/a | `bool` | `true` | no |
| <a name="input_extra_kms_policies"></a> [extra\_kms\_policies](#input\_extra\_kms\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_extra_s3_athena_policies"></a> [extra\_s3\_athena\_policies](#input\_extra\_s3\_athena\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_extra_s3_log_policies"></a> [extra\_s3\_log\_policies](#input\_extra\_s3\_log\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_kms_base_policy"></a> [kms\_base\_policy](#input\_kms\_base\_policy) | Optional base KMS key-policy statements to apply to module-created CMKs before module-required service access statements are merged in. If null, the module defaults to the historical root `kms:*` statement. | <pre>list(object({<br/>    sid    = string<br/>    effect = string<br/>    principals = object({<br/>      type        = string<br/>      identifiers = list(string)<br/>    })<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `null` | no |
| <a name="input_lambda_log_retention_in_days"></a> [lambda\_log\_retention\_in\_days](#input\_lambda\_log\_retention\_in\_days) | CloudWatch log retention in days for the re-encrypt and sweep Lambda functions | `number` | `365` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | n/a | `string` | `"fleet"` | no |
| <a name="input_s3_expiration_days"></a> [s3\_expiration\_days](#input\_s3\_expiration\_days) | n/a | `number` | `90` | no |
| <a name="input_s3_newer_noncurrent_versions"></a> [s3\_newer\_noncurrent\_versions](#input\_s3\_newer\_noncurrent\_versions) | n/a | `number` | `5` | no |
| <a name="input_s3_noncurrent_version_expiration_days"></a> [s3\_noncurrent\_version\_expiration\_days](#input\_s3\_noncurrent\_version\_expiration\_days) | n/a | `number` | `30` | no |
| <a name="input_s3_transition_days"></a> [s3\_transition\_days](#input\_s3\_transition\_days) | n/a | `number` | `30` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_log_s3_bucket_id"></a> [log\_s3\_bucket\_id](#output\_log\_s3\_bucket\_id) | S3 bucket used by ALB access logging (SSE-S3 on write, re-encrypted to SSE-KMS by Lambda) |
