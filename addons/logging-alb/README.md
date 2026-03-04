# ALB Logging Addon
This addon creates an SSE-S3 landing bucket for ALB access logs, replicates those logs into an SSE-KMS archive bucket, and optionally creates Athena resources for querying the replicated logs.

# Example Configuration

This assumes your fleet module is `main` and is configured with it's default documentation.

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

For this implementation, the S3 pattern for the `CREATE TABLE` query should use the archive bucket and look like this:

```
s3://your-alb-logs-archive-bucket/<PREFIX>/AWSLogs/<ACCOUNT-ID>/elasticloadbalancing/<REGION>/
```

## Migration

Upgrades from older versions should use a two-phase migration:

1. Set `landing_s3_expiration_days` to a value larger than `1` so existing landing-bucket objects are retained during the backfill window.
2. Apply Terraform so the archive bucket and live replication are in place.
3. Start the historical backfill with `scripts/start-batch-replication-migration.sh`.
4. Wait for the batch job to finish and validate that Athena can query the archive bucket data.
5. Set `landing_s3_expiration_days` back to `1` and apply Terraform again.

Terraform will emit a non-blocking check warning whenever `landing_s3_expiration_days` is set to something other than `1`.

Example backfill command:

```
./scripts/start-batch-replication-migration.sh \
  --source-bucket fleet-alb-logs \
  --report-bucket fleet-alb-logs
```

The script submits an S3 Batch Replication job for existing objects that match the bucket's replication configuration. It creates or updates a Batch Operations IAM role automatically if you do not provide `--batch-role-arn`.

If the report bucket uses SSE-KMS, also pass `--report-kms-key-arn`.

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.34.0 |

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
| [aws_glue_catalog_table.partitioned_alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_iam_role.s3_replication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.s3_replication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.logs_alias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.logs_archive](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.logs_archive](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.logs_archive](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_replication_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_replication_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.logs_archive](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.logs_archive](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_athena_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_log_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_replication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_replication_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alt_path_prefix"></a> [alt\_path\_prefix](#input\_alt\_path\_prefix) | Used if the prefix inside of the s3 bucket doesn't match the name of the bucket prefix | `string` | `null` | no |
| <a name="input_enable_athena"></a> [enable\_athena](#input\_enable\_athena) | n/a | `bool` | `true` | no |
| <a name="input_extra_kms_policies"></a> [extra\_kms\_policies](#input\_extra\_kms\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_extra_s3_athena_policies"></a> [extra\_s3\_athena\_policies](#input\_extra\_s3\_athena\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_extra_s3_log_policies"></a> [extra\_s3\_log\_policies](#input\_extra\_s3\_log\_policies) | n/a | `list(any)` | `[]` | no |
| <a name="input_landing_s3_expiration_days"></a> [landing\_s3\_expiration\_days](#input\_landing\_s3\_expiration\_days) | Retention in days for the SSE-S3 landing bucket. Keep this at 1 after migration; increase it temporarily for phased backfills. | `number` | `1` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | n/a | `string` | `"fleet"` | no |
| <a name="input_s3_expiration_days"></a> [s3\_expiration\_days](#input\_s3\_expiration\_days) | n/a | `number` | `90` | no |
| <a name="input_s3_newer_noncurrent_versions"></a> [s3\_newer\_noncurrent\_versions](#input\_s3\_newer\_noncurrent\_versions) | n/a | `number` | `5` | no |
| <a name="input_s3_noncurrent_version_expiration_days"></a> [s3\_noncurrent\_version\_expiration\_days](#input\_s3\_noncurrent\_version\_expiration\_days) | n/a | `number` | `30` | no |
| <a name="input_s3_transition_days"></a> [s3\_transition\_days](#input\_s3\_transition\_days) | n/a | `number` | `30` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_archive_log_s3_bucket_id"></a> [archive\_log\_s3\_bucket\_id](#output\_archive\_log\_s3\_bucket\_id) | SSE-KMS archive bucket used for retained ALB logs and Athena table data |
| <a name="output_log_s3_bucket_id"></a> [log\_s3\_bucket\_id](#output\_log\_s3\_bucket\_id) | SSE-S3 landing bucket used by ALB access logging |
