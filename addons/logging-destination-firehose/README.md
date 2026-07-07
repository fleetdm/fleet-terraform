# Logging Destination: Firehose

This addon provides a Kinesis Firehose logging destination for Fleet.

## S3 Bucket Policy: Deny Non-HTTPS

This module automatically attaches a bucket policy to each S3 bucket that denies any requests made over plain HTTP. No configuration is required.

## Configuration

The module creates Kinesis Firehose delivery streams that deliver osquery results, status, and audit logs to S3. Delivery streams are configured via the `log_destinations` map, allowing per-stream tuning of buffering, compression, and partitioning.

By default (`consolidate_to_single_bucket = false`), each log type gets its own S3 bucket, matching the legacy layout. Set `consolidate_to_single_bucket = true` to share a single bucket partitioned by prefix.

### Key Features

- **Customer-managed KMS encryption** — creates a KMS key by default, or accepts an existing key ARN via `kms_key_arn`
- **Firehose server-side encryption** with `CUSTOMER_MANAGED_CMK`
- **S3 bucket encryption** with the same CMK (`kms_master_key_id` wired into the bucket SSE config)
- **Date-based S3 partitioning** — files are organized by `year/month/day` under each log type prefix
- **Error output prefixes** — failed deliveries are routed to separate partitioned paths
- **Configurable buffering** — per-stream `buffering_size` and `buffering_interval`
- **Per-destination bucket names** — each `log_destinations` entry can specify its own `bucket_name` (defaults to `<s3_bucket_name>-<key>`)
- **Per-destination lifecycle expiration** — each `log_destinations` entry can specify its own `lifecycle_expires_days` (defaults to `s3_lifecycle_expires_days`)
- **`force_destroy`** — configurable via `s3_force_destroy` (disabled by default)

### Stream Key Mapping

Fleet requires three specific environment variables pointing to Firehose delivery streams. The variables `fleet_firehose_result_stream_key`, `fleet_firehose_status_stream_key`, and `fleet_firehose_audit_stream_key` map Fleet's env vars to keys in `log_destinations`. By default these map to `results`, `status`, and `audit` respectively.

## Migration from Legacy Module

The previous version of this module used three separate variables (`osquery_results_s3_bucket`, `osquery_status_s3_bucket`, `audit_s3_bucket`) and created three separate S3 buckets, IAM roles, and delivery streams. This version uses a unified `log_destinations` map and `for_each` resources.

### Step 1: Update your module configuration

Replace your old configuration with the new variable names. The `moved` blocks in this module ensure Terraform renames existing resources in state rather than destroying them.

**Before (legacy):**

```hcl
module "firehose_logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-firehose"

  osquery_results_s3_bucket = {
    name         = "fleet-osquery-results-archive"
    expires_days = 1
  }
  osquery_status_s3_bucket = {
    name         = "fleet-osquery-status-archive"
    expires_days = 1
  }
  audit_s3_bucket = {
    name         = "fleet-audit-archive"
    expires_days = 1
  }
  compression_format = "UNCOMPRESSED"
}
```

**After (new):**

```hcl
module "firehose_logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-firehose"

  s3_force_destroy               = false
  server_side_encryption_enabled = true

  # IMPORTANT: Set bucket_name in each log destination to match your
  # existing bucket names exactly. S3 bucket names are immutable — if
  # these do not match, Terraform will plan to destroy and recreate
  # the buckets, causing data loss.
  #
  # Set lifecycle_expires_days per destination to preserve your legacy
  # per-bucket retention values.
  log_destinations = {
    results = {
      name                    = "osquery_results"
      bucket_name             = "fleet-osquery-results-archive"
      lifecycle_expires_days  = 1
      prefix                  = "results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "results/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
    status = {
      name                    = "osquery_status"
      bucket_name             = "fleet-osquery-status-archive"
      lifecycle_expires_days  = 1
      prefix                  = "status/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "status/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
    audit = {
      name                    = "fleet_audit"
      bucket_name             = "fleet-audit-archive"
      lifecycle_expires_days  = 1
      prefix                  = "audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix     = "audit/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      buffering_size          = 20
      buffering_interval      = 120
      compression_format      = "UNCOMPRESSED"
    }
  }
}
```

### Step 2: Run `terraform plan`

Terraform will show the resources being **moved** (renamed in state) and the new features being **added** (KMS key, SSE config updates, buffering settings, partitioning). No resources will be destroyed or replaced.

```
Terraform will perform the following actions:

  # aws_s3_bucket.osquery-results has moved to aws_s3_bucket.destination["results"]
  # aws_s3_bucket.osquery-status has moved to aws_s3_bucket.destination["status"]
  # aws_s3_bucket.audit has moved to aws_s3_bucket.destination["audit"]
  ...
```

### Step 3: Run `terraform apply`

Apply the changes. All existing data in your S3 buckets is preserved. The Firehose delivery streams continue to write to the same buckets. The `moved` blocks ensure Terraform renames resources in state rather than destroying and recreating them.

### Optional: Consolidate to a single bucket

After migrating to the 3-bucket layout, you can optionally consolidate all log types into a single S3 bucket by setting `consolidate_to_single_bucket = true`. The `moved` blocks in this module do **not** support this path — you cannot move 3 buckets into 1 bucket via state renames. This requires a data and configuration migration.

Recommended approach:

1. **Set `consolidate_to_single_bucket = true`** in your module configuration and set `s3_bucket_name` to the desired name for the single shared bucket. Run `terraform plan` to review — it will show a new bucket being created and the existing 3 buckets marked for destruction.

2. **Remove the old 3 buckets from state** so Terraform does not destroy them during the apply:
   ```bash
   terraform state rm 'module.firehose_logging.aws_s3_bucket.destination["results"]'
   terraform state rm 'module.firehose_logging.aws_s3_bucket.destination["status"]'
   terraform state rm 'module.firehose_logging.aws_s3_bucket.destination["audit"]'
   ```
   Also remove the associated lifecycle, SSE, public access, and policy resources for each bucket key.

3. **Apply** to create the new single bucket and update delivery streams to write to it.

4. **Migrate data** from the old 3 buckets to the new single bucket (e.g., using `aws s3 sync` with appropriate prefix filters).

5. **Update Fleet** to point to the new Firehose delivery streams.

6. **Clean up the old buckets** manually in AWS (console or CLI) once you have confirmed data has been migrated and Fleet is using the new streams. The old buckets are no longer managed by Terraform, so Terraform will not destroy them.

### Migration from prior single-bucket version

If you used the prior single-bucket version of this module (singleton resources such as `aws_s3_bucket.destination`, `aws_iam_role.firehose`, etc.), the `moved` blocks in this module do **not** cover your case. Migrating from a single shared bucket to the default 3-bucket layout requires creating new buckets and updating Firehose delivery streams to write to them — this is a data migration, not a state rename.

Recommended approach:

1. **Remove old singleton resources from state.** Before updating your configuration, run `terraform state rm` for each old resource so Terraform stops managing them and does not plan to destroy them:
   ```bash
   terraform state rm 'module.firehose_logging.aws_s3_bucket.destination'
   terraform state rm 'module.firehose_logging.aws_s3_bucket_public_access_block.destination'
   terraform state rm 'module.firehose_logging.aws_s3_bucket_server_side_encryption_configuration.destination'
   terraform state rm 'module.firehose_logging.aws_s3_bucket_lifecycle_configuration.destination'
   terraform state rm 'module.firehose_logging.aws_s3_bucket_policy.deny_insecure_transport'
   terraform state rm 'module.firehose_logging.aws_iam_role.firehose'
   terraform state rm 'module.firehose_logging.aws_iam_policy.firehose'
   terraform state rm 'module.firehose_logging.aws_iam_role_policy_attachment.firehose'
   ```
   These resources still exist in AWS but are no longer tracked by Terraform.

2. **Update your configuration** to the new `log_destinations` map with `consolidate_to_single_bucket = false` (default). Run `terraform plan` to verify only new resources are created.

3. **Apply** to create the new 3-bucket resources and delivery streams.

4. **Migrate data** from the old single bucket to the new buckets (e.g., using `aws s3 sync` with appropriate prefix filters).

5. **Update Fleet** to point to the new Firehose delivery streams.

6. **Clean up the old bucket** manually in AWS (console or CLI) once you have confirmed data has been migrated and Fleet is using the new streams. The old bucket is no longer managed by Terraform, so Terraform will not destroy it.

### Output changes

The old module exposed three separate S3 config outputs. The new module exposes a single `fleet_s3_firehose_config` output keyed by bucket key. Update any downstream references accordingly.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.37.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.53.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.firehose-logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.firehose](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kinesis_firehose_delivery_stream.fleet_log_destinations](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kinesis_firehose_delivery_stream) | resource |
| [aws_kms_key.firehose_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_policy.deny_insecure_transport](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.destination](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.deny_insecure_transport](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.firehose_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_consolidate_to_single_bucket"></a> [consolidate\_to\_single\_bucket](#input\_consolidate\_to\_single\_bucket) | When true, all log types share a single S3 bucket partitioned by prefix. When false (default), each log type gets its own S3 bucket. Default false preserves the legacy 3-bucket layout for seamless migration. | `bool` | `false` | no |
| <a name="input_fleet_firehose_audit_stream_key"></a> [fleet\_firehose\_audit\_stream\_key](#input\_fleet\_firehose\_audit\_stream\_key) | The key in var.log\_destinations that provides the audit stream. Must match a key in log\_destinations. | `string` | `"audit"` | no |
| <a name="input_fleet_firehose_result_stream_key"></a> [fleet\_firehose\_result\_stream\_key](#input\_fleet\_firehose\_result\_stream\_key) | The key in var.log\_destinations that provides the osquery results stream. Must match a key in log\_destinations. | `string` | `"results"` | no |
| <a name="input_fleet_firehose_status_stream_key"></a> [fleet\_firehose\_status\_stream\_key](#input\_fleet\_firehose\_status\_stream\_key) | The key in var.log\_destinations that provides the osquery status stream. Must match a key in log\_destinations. | `string` | `"status"` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | An optional KMS key ARN for server-side encryption. If not provided and encryption is enabled, a new key will be created. | `string` | `""` | no |
| <a name="input_log_destinations"></a> [log\_destinations](#input\_log\_destinations) | A map of configurations for Firehose delivery streams. | <pre>map(object({<br/>    name                    = string<br/>    bucket_name             = optional(string, null)<br/>    lifecycle_expires_days  = optional(number, null)<br/>    prefix                  = string<br/>    error_output_prefix     = string<br/>    buffering_size          = number<br/>    buffering_interval      = number<br/>    compression_format      = string<br/>  }))</pre> | <pre>{<br/>  "audit": {<br/>    "bucket_name": null,<br/>    "buffering_interval": 120,<br/>    "buffering_size": 20,<br/>    "compression_format": "UNCOMPRESSED",<br/>    "error_output_prefix": "audit/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/",<br/>    "lifecycle_expires_days": null,<br/>    "name": "fleet_audit",<br/>    "prefix": "audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"<br/>  },<br/>  "results": {<br/>    "bucket_name": null,<br/>    "buffering_interval": 120,<br/>    "buffering_size": 20,<br/>    "compression_format": "UNCOMPRESSED",<br/>    "error_output_prefix": "results/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/",<br/>    "lifecycle_expires_days": null,<br/>    "name": "osquery_results",<br/>    "prefix": "results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"<br/>  },<br/>  "status": {<br/>    "bucket_name": null,<br/>    "buffering_interval": 120,<br/>    "buffering_size": 20,<br/>    "compression_format": "UNCOMPRESSED",<br/>    "error_output_prefix": "status/error/error=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/",<br/>    "lifecycle_expires_days": null,<br/>    "name": "osquery_status",<br/>    "prefix": "status/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"<br/>  }<br/>}</pre> | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | n/a | `string` | `""` | no |
| <a name="input_s3_bucket_name"></a> [s3\_bucket\_name](#input\_s3\_bucket\_name) | Base name for S3 buckets. When consolidate\_to\_single\_bucket is false (default), each bucket name defaults to '<s3\_bucket\_name>-<key>' unless overridden by bucket\_name in log\_destinations. When true, this is the single shared bucket name. | `string` | `"fleet-osquery-logging-archive"` | no |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Whether to allow the S3 bucket(s) to be destroyed even if they contain objects. | `bool` | `false` | no |
| <a name="input_s3_lifecycle_expires_days"></a> [s3\_lifecycle\_expires\_days](#input\_s3\_lifecycle\_expires\_days) | Default number of days after which objects in the S3 bucket(s) expire. Set to 0 to disable lifecycle expiration. Can be overridden per-destination via log\_destinations[*].lifecycle\_expires\_days. | `number` | `0` | no |
| <a name="input_server_side_encryption_enabled"></a> [server\_side\_encryption\_enabled](#input\_server\_side\_encryption\_enabled) | Enable server-side encryption on the Firehose delivery streams and S3 bucket(s). | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_fleet_extra_environment_variables"></a> [fleet\_extra\_environment\_variables](#output\_fleet\_extra\_environment\_variables) | n/a |
| <a name="output_fleet_extra_iam_policies"></a> [fleet\_extra\_iam\_policies](#output\_fleet\_extra\_iam\_policies) | n/a |
| <a name="output_fleet_s3_firehose_config"></a> [fleet\_s3\_firehose\_config](#output\_fleet\_s3\_firehose\_config) | S3 bucket details for Firehose delivery, keyed by bucket key. |
| <a name="output_log_destinations"></a> [log\_destinations](#output\_log\_destinations) | Map of Firehose delivery stream names. |
