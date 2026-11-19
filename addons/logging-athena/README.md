# Athena Logging Addon

This addon is the read side of Fleet's S3 log destinations. It creates an Athena database, workgroup,
and query-results bucket, points Glue tables at log buckets it does **not** own, and layers views on
top so a third-party data modelling or BI application can use Athena as its data connector.

It creates no log buckets and never writes log data. Because it consumes only bucket names and
prefixes, it works against `logging-destination-firehose` in the same account and equally against the
BYO and cross-account destinations (`byo-firehose-logging-destination`,
`byo-kinesis-logging-destination`, `byo-cloudwatch-log-sharing`).

## Prerequisites

Two settings on the logging module are effectively required before this addon is useful:

1. **Partitioned prefixes.** The delivery streams must write Hive-style partitions. Set
   `firehose_s3_prefix` to `data/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/` for the default
   `partition_layout = "hourly"`, or `data/dt=!{timestamp:yyyy-MM-dd}/` for `"daily"`. Also set
   `firehose_s3_error_output_prefix` to a path **outside** the table location (e.g.
   `errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/`), or failed records land inside
   the partition tree.
2. **Retention worth querying.** `logging-destination-firehose` defaults every bucket's
   `expires_days` to `1`. An analytics layer over one day of data is a toy; raise it before enabling
   this addon.

`compression_format = "GZIP"` on the delivery streams is also strongly recommended. Athena reads
Firehose's `.gz` output transparently and scans roughly 5-10x fewer bytes, which is billed directly.

Note that Firehose partitions on record **arrival** time, not event time. Fleet buffers and osquery
batches, so an event near midnight can land in the neighbouring partition. Queries that filter on
`event_time` must widen the `dt` predicate by a day on each side; the shipped named queries
demonstrate the pattern.

## Example Configuration

The prefix is defined once in the caller and passed to both modules, which keeps the delivered keys
and the Glue table location in sync from a single source of truth. This module validates the prefix
against `partition_layout` at plan time.

```hcl
locals {
  fleet_log_prefix = "data/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/"
}

module "firehose-logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-firehose?ref=main"

  compression_format              = "GZIP"
  firehose_s3_prefix              = local.fleet_log_prefix
  firehose_s3_error_output_prefix = "errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"

  osquery_results_s3_bucket = { name = "fleet-osquery-results-archive", expires_days = 395 }
  osquery_status_s3_bucket  = { name = "fleet-osquery-status-archive", expires_days = 90 }
  audit_s3_bucket           = { name = "fleet-audit-archive", expires_days = 395 }
}

module "fleet-athena" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-athena?ref=main"

  prefix = "fleet"

  osquery_results = {
    bucket_name        = module.firehose-logging.fleet_s3_firehose_osquery_results_config.bucket_name
    firehose_s3_prefix = local.fleet_log_prefix
  }
  osquery_status = {
    bucket_name        = module.firehose-logging.fleet_s3_firehose_osquery_status_config.bucket_name
    firehose_s3_prefix = local.fleet_log_prefix
  }
  fleet_audit = {
    bucket_name        = module.firehose-logging.fleet_s3_firehose_audit_config.bucket_name
    firehose_s3_prefix = local.fleet_log_prefix
  }

  # Fleet's default agent options provide these two. Confirm against
  # your own environment before committing to them.
  decoration_columns = ["host_uuid", "hostname"]

  consumer_role = {
    enabled            = true
    trusted_principals = ["arn:aws:iam::111122223333:root"]
    external_id        = "some-vendor-supplied-external-id"
  }
}
```

## Tables

Three tables describe what osquery and Fleet actually emit, with no normalisation. Query the views
instead unless you need the untouched record shapes.

| Table | Source | SerDe |
| ----- | ------ | ----- |
| `osquery_results_raw` | osquery result logs | OpenX JSON |
| `osquery_status_raw` | osquery status logs | OpenX JSON |
| `fleet_audit_raw` | Fleet activity audit log | one JSON document per row |

Fleet appends a newline to every Firehose record (`server/logging/firehose.go`) precisely because
Firehose does not delimit records itself, so the delivered objects are valid NDJSON and nothing has to
transform them.

Partition projection is used throughout, so there is no crawler and no `MSCK REPAIR TABLE`.

### Why `map<string,string>` and not JSON

Athena's `json` type exists only in the query engine, not in DDL -- Glue table columns use Hive types,
which have no JSON. The choice is therefore between a SerDe-parsed complex type and a `string` shredded
with `json_extract` at query time.

For `columns`, `snapshot`, and `decorations` the SerDe-parsed map wins: osquery emits every value as a
string under Fleet's defaults (`numerics: false`), so the map is lossless, and the SerDe parses each
record once during the scan instead of re-parsing per `json_extract_scalar` call. The views also expose
`row_columns_json` and `decorations_json`, because JDBC/ODBC renders a `map<>` as unparseable
`{k=v, k=v}` text that many BI tools cannot navigate.

Fleet's audit `details` field is the exception. It has a different shape per activity type and
arbitrary nesting, so `fleet_audit_raw` holds one column with the whole record and the view extracts
fields with `json_extract_scalar`.

### Key case

`case_insensitive_keys` defaults to `false`, which preserves key case and adds explicit `mapping.*`
entries for osquery's camelCase top-level fields. The OpenX SerDe's default of `true` lowercases keys
*inside* maps as well, which silently mangles mixed-case osquery column names, `SELECT x AS myColumn`
aliases, and deployment-defined decoration keys, and collapses keys differing only in case.

## Views

Five views are created as native Glue `VIRTUAL_VIEW` tables. An Athena view is a Glue table whose
definition is a base64-encoded document in `view_original_text`, so Terraform manages them directly:
no compute, no invocation-on-apply, and `terraform destroy` removes them cleanly.

| View | Reads from | Contents |
| ---- | ---------- | -------- |
| `osquery_results` | `osquery_results_raw` | One row per result row, all four osquery serialisations normalised |
| `osquery_snapshots` | `osquery_results` | `action = 'snapshot'` |
| `osquery_differential` | `osquery_results` | `action IN ('added','removed')` |
| `osquery_status` | `osquery_status_raw` | Status logs with severity, line, and timestamps typed |
| `fleet_audit` | `fleet_audit_raw` | Audit records with scalars typed and `details` left as JSON text |

Result, status, and audit logs stay fundamentally separate. They arrive on three delivery streams,
land in three buckets, and get three tables; no view unions or joins across them.

These five are a baseline, not a boundary. Supplementary views are yours to create in the same
database -- `athena_database_force_destroy` defaults to `false` so a `terraform destroy` fails rather
than dropping them as collateral, and the `Template: typed per-query view` named query is a starting
point.

`osquery_results` collapses **serialisation** only. osquery delivers the same data four ways depending
on agent options -- event format, snapshot arrays, snapshot-as-events, and batch format -- and which
one arrives is a deployment detail that can differ between hosts in the same fleet. The
snapshot-vs-differential distinction is semantic and is preserved verbatim in `action`, with
`result_format` recording the wire shape each row came from. `osquery_snapshots` and
`osquery_differential` exist because mixing point-in-time state rows with change rows makes aggregate
counts meaningless.

Snapshot rows carry `snapshot_row_num` (delivered order, via `WITH ORDINALITY`) and
`snapshot_row_count`, so a consumer can confirm a snapshot arrived whole without a self-join.

### How the view schemas stay honest

A Glue view declares its output schema twice: Trino types inside the encoded definition, and Hive
types in the storage descriptor. If either disagrees with what the SQL actually produces, the failure
surfaces at query time for the consumer rather than at apply time here.

So each view is defined by one projection list in `views.tf` holding the SQL expression alongside both
type spellings, and the `SELECT` text and both schemas are generated from it -- they cannot drift.
Projections are explicitly `CAST` wherever the result type would otherwise be inferred, because a bare
`'event'` literal is `varchar(5)` rather than `varchar`, and `UNION ALL` over differently-sized
varchars coerces to the widest.

### Reading result columns downstream

Use `element_at(row_columns, 'col')`, never `row_columns['col']` -- subscript raises
`Key not present in map` for rows produced by a query that lacks that column, which fails the whole
statement rather than returning NULL. osquery also emits empty strings rather than nulls, so wrap
casts as `TRY_CAST(NULLIF(element_at(row_columns, 'col'), '') AS bigint)`. The
`Template: typed per-query view` named query is a working starting point.

Keep `dt` (and `hour`) in the select list of any view built on these. A view that drops them leaves
consumers unable to write a partition predicate, and every query becomes a full-bucket scan.

## Host identity

Host identity in this data is weaker than it looks, and this module does not paper over it.

For **result logs**, `host_identifier` is always present, but its meaning is set by the server's
`FLEET_OSQUERY_HOST_IDENTIFIER` setting (`uuid`, `instance`, `hostname`, or `provided`). It is
reliably populated, not reliably a UUID.

For **status logs** there is no host field at all -- Fleet writes status logs through untouched
(`server/service/osquery.go`, `SubmitStatusLogs`), and osquery does not include `hostIdentifier` in
them. The only possible correlation is via `decorations`.

Decorations themselves are deployment-defined: agent options can add, rename, or disable them
entirely. This module therefore treats `decorations` as an opaque map, projects nothing by default,
and never subscripts it. Set `decoration_columns` to project the keys your environment actually emits
as `decoration_<key>` columns; Fleet's default agent options supply `host_uuid` and `hostname`. Confirm
with the `Example: which decorations does this environment emit?` named query before committing.

## Encryption

The query-results bucket and the workgroup's output are encrypted with a customer-managed key. Supply
`kms_key_arn` to use an existing key, or leave it null to have the module create one.

When the source log buckets are encrypted with a CMK (`s3_kms_encryption_enabled = true` on
`logging-destination-firehose`), pass that key's ARN as `source_kms_key_arns` so the consumer role can
decrypt log data, and feed this module's `consumer_role_arn` output into the logging module's
`kms_extra_policies` so the key policy permits it.

## Cost controls

The workgroup enforces its own result location and encryption and sets
`bytes_scanned_cutoff_per_query` (10 GiB by default) so an unpartitioned `SELECT *` fails instead of
billing. Query results expire after `query_results_expiration_days` (30 by default).

Converting the raw JSON to Parquet would cut scan costs further and is the obvious next step if a
modelling tool does frequent full-table refreshes, but it is deliberately out of scope here: Firehose
record-format conversion needs a concrete Glue schema, which the arbitrary `columns` map does not
have, and a scheduled CTAS job is a separate piece of machinery worth adding only once scan costs
justify it.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.57.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_query_results_bucket"></a> [query\_results\_bucket](#module\_query\_results\_bucket) | terraform-aws-modules/s3-bucket/aws | 5.12.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_athena_database.fleet_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_database) | resource |
| [aws_athena_named_query.example_decoration_discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_named_query) | resource |
| [aws_athena_named_query.example_recent_results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_named_query) | resource |
| [aws_athena_named_query.example_typed_query_view](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_named_query) | resource |
| [aws_athena_workgroup.fleet_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_workgroup) | resource |
| [aws_glue_catalog_table.fleet_audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_glue_catalog_table.osquery_results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_glue_catalog_table.osquery_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_glue_catalog_table.views](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_table) | resource |
| [aws_iam_role.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.consumer_extra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.athena](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.athena](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key_policy.athena](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [terraform_data.validate_at_least_one_source](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.validate_kms_extra_policies](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.validate_source_prefixes](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.athena_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.consumer_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.query_results_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_athena_database_force_destroy"></a> [athena\_database\_force\_destroy](#input\_athena\_database\_force\_destroy) | Allow `terraform destroy` to delete the Athena database while it still contains tables. Defaults to false so supplementary views created by your team or by a modelling tool are not destroyed as collateral -- a destroy will fail instead, and you can drop them deliberately. | `bool` | `false` | no |
| <a name="input_bytes_scanned_cutoff_per_query"></a> [bytes\_scanned\_cutoff\_per\_query](#input\_bytes\_scanned\_cutoff\_per\_query) | Per-query data scanned limit enforced by the workgroup, in bytes. Guards against unpartitioned full-bucket scans. Set to null to disable. AWS requires at least 10 MB. | `number` | `10737418240` | no |
| <a name="input_case_insensitive_keys"></a> [case\_insensitive\_keys](#input\_case\_insensitive\_keys) | OpenX JSON SerDe `case.insensitive` setting.<br/><br/>`false` (default) preserves key case and adds explicit `mapping.*` entries for osquery's<br/>camelCase top-level fields. `true` is simpler but lowercases keys *inside* maps as well,<br/>silently mangling mixed-case osquery column names, `SELECT x AS myColumn` aliases, and<br/>deployment-defined decoration keys, and collapsing keys that differ only in case. | `bool` | `false` | no |
| <a name="input_consumer_role"></a> [consumer\_role](#input\_consumer\_role) | Read-only role for a third-party data modelling or BI application to assume as its Athena<br/>data connector.<br/><br/>`trusted_principals` are the ARNs allowed to assume it (an account root such as<br/>`arn:aws:iam::111122223333:root`, or a specific role ARN). Set `external_id` to require<br/>`sts:ExternalId` on assumption, which vendors that support it should always be given. | <pre>object({<br/>    enabled            = optional(bool, false)<br/>    name               = optional(string, null)<br/>    trusted_principals = optional(list(string), [])<br/>    external_id        = optional(string, null)<br/>    extra_policy_arns  = optional(list(string), [])<br/>    max_session_hours  = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | Glue/Athena database name. Defaults to `<prefix>_fleet_logs` with dashes replaced by underscores. | `string` | `null` | no |
| <a name="input_decoration_columns"></a> [decoration\_columns](#input\_decoration\_columns) | Decoration keys to project as top-level `decoration_<key>` columns in the results and status views.<br/><br/>Decorations are deployment-defined: agent options can add, rename, or disable them entirely, so<br/>this module makes no assumption and defaults to none. Fleet's default agent options provide<br/>`host_uuid` and `hostname`, which most deployments will want here. The raw `decorations` map and<br/>`decorations_json` are always exposed regardless, and the decoration-discovery named query finds<br/>what a given environment actually emits. | `list(string)` | `[]` | no |
| <a name="input_example_named_queries"></a> [example\_named\_queries](#input\_example\_named\_queries) | Save example analytic queries as Athena named queries, for discoverability in the console. These demonstrate the partition-widening pattern, decoration discovery, and a typed per-query view template; they create nothing. | `bool` | `true` | no |
| <a name="input_extra_s3_athena_policies"></a> [extra\_s3\_athena\_policies](#input\_extra\_s3\_athena\_policies) | Extra bucket policy statements to attach to the query-results bucket. | `list(any)` | `[]` | no |
| <a name="input_fleet_audit"></a> [fleet\_audit](#input\_fleet\_audit) | Fleet activity audit log source. See `osquery_results` for the shape and prefix requirements. | <pre>object({<br/>    enabled            = optional(bool, true)<br/>    bucket_name        = string<br/>    firehose_s3_prefix = string<br/>  })</pre> | `null` | no |
| <a name="input_kms_base_policy"></a> [kms\_base\_policy](#input\_kms\_base\_policy) | Optional base KMS key-policy statements applied to the module-created CMK before module-required access statements are merged in. If null, the module defaults to the historical root `kms:*` statement. | <pre>list(object({<br/>    sid    = string<br/>    effect = string<br/>    principals = object({<br/>      type        = string<br/>      identifiers = list(string)<br/>    })<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `null` | no |
| <a name="input_kms_extra_policies"></a> [kms\_extra\_policies](#input\_kms\_extra\_policies) | Extra KMS key-policy statements for the module-created CMK. Only valid when this module creates the key (`kms_key_arn` is null). | `list(any)` | `[]` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of an existing KMS key to encrypt the query-results bucket and workgroup output. When null, this module creates one. | `string` | `null` | no |
| <a name="input_osquery_results"></a> [osquery\_results](#input\_osquery\_results) | osquery result log source. `bucket_name` is the S3 bucket the results delivery stream writes to.<br/>`firehose_s3_prefix` must be the same value passed to the delivery stream's `firehose_s3_prefix`,<br/>including the `!{timestamp:...}` expressions, so the Glue table location can be derived from it. | <pre>object({<br/>    enabled            = optional(bool, true)<br/>    bucket_name        = string<br/>    firehose_s3_prefix = string<br/>  })</pre> | `null` | no |
| <a name="input_osquery_status"></a> [osquery\_status](#input\_osquery\_status) | osquery status log source. See `osquery_results` for the shape and prefix requirements. | <pre>object({<br/>    enabled            = optional(bool, true)<br/>    bucket_name        = string<br/>    firehose_s3_prefix = string<br/>  })</pre> | `null` | no |
| <a name="input_pack_delimiter"></a> [pack\_delimiter](#input\_pack\_delimiter) | The `pack_delimiter` osquery agent option, used to split `pack<delim>{Global|team-<id>}<delim><query name>` in the views. Restricted to characters that are safe to embed in a regular expression. | `string` | `"/"` | no |
| <a name="input_partition_layout"></a> [partition\_layout](#input\_partition\_layout) | Partition granularity delivered by Firehose. `hourly` expects<br/>`<static>/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/`, `daily` expects<br/>`<static>/dt=!{timestamp:yyyy-MM-dd}/`. Partition projection is used in both cases, so no<br/>crawler or MSCK REPAIR is required. | `string` | `"hourly"` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Prefix used to name the Athena database, workgroup, query-results bucket, and IAM resources. | `string` | `"fleet"` | no |
| <a name="input_projection_start_date"></a> [projection\_start\_date](#input\_projection\_start\_date) | First date partition projection will consider, `yyyy-MM-dd`. Queries cannot see data delivered before this date, so set it at or before the date the delivery streams started writing partitioned keys. | `string` | `"2025-01-01"` | no |
| <a name="input_query_results_bucket_name"></a> [query\_results\_bucket\_name](#input\_query\_results\_bucket\_name) | Name of the Athena query-results bucket. Defaults to `<prefix>-fleet-logs-athena`. | `string` | `null` | no |
| <a name="input_query_results_expiration_days"></a> [query\_results\_expiration\_days](#input\_query\_results\_expiration\_days) | Lifecycle expiration in days for Athena query results and metadata. | `number` | `30` | no |
| <a name="input_s3_bucket_tags"></a> [s3\_bucket\_tags](#input\_s3\_bucket\_tags) | Additional tags to apply to the S3 bucket created by this module. | `map(string)` | `{}` | no |
| <a name="input_source_kms_key_arns"></a> [source\_kms\_key\_arns](#input\_source\_kms\_key\_arns) | ARNs of the CMKs encrypting the source log buckets. Required for the consumer role to read log data when the logging module is configured with `s3_kms_encryption_enabled = true`. Leave empty when the buckets use the AWS-managed S3 key. | `list(string)` | `[]` | no |
| <a name="input_table_prefix"></a> [table\_prefix](#input\_table\_prefix) | Optional prefix applied to every table and view name in the database, e.g. `staging_`. | `string` | `""` | no |
| <a name="input_workgroup_name"></a> [workgroup\_name](#input\_workgroup\_name) | Athena workgroup name. Defaults to `<prefix>-fleet-logs`. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_athena_database_name"></a> [athena\_database\_name](#output\_athena\_database\_name) | Glue/Athena database holding the Fleet log tables and views. |
| <a name="output_athena_workgroup_arn"></a> [athena\_workgroup\_arn](#output\_athena\_workgroup\_arn) | ARN of the Athena workgroup. |
| <a name="output_athena_workgroup_name"></a> [athena\_workgroup\_name](#output\_athena\_workgroup\_name) | Athena workgroup to point a data connector at. Its result location and encryption are enforced, so clients do not need to supply an output location. |
| <a name="output_consumer_role_arn"></a> [consumer\_role\_arn](#output\_consumer\_role\_arn) | ARN of the read-only role for a third-party data modelling application. Null when consumer\_role.enabled is false. Pass this into the logging module's kms\_extra\_policies when the log buckets are encrypted with a module-created CMK. |
| <a name="output_consumer_role_name"></a> [consumer\_role\_name](#output\_consumer\_role\_name) | Name of the read-only consumer role. Null when consumer\_role.enabled is false. |
| <a name="output_kms_key_alias"></a> [kms\_key\_alias](#output\_kms\_key\_alias) | Alias of the module-created KMS key. Null when an existing key was supplied. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key encrypting the query-results bucket and the workgroup's output. |
| <a name="output_query_results_bucket_arn"></a> [query\_results\_bucket\_arn](#output\_query\_results\_bucket\_arn) | ARN of the Athena query-results bucket. |
| <a name="output_query_results_bucket_id"></a> [query\_results\_bucket\_id](#output\_query\_results\_bucket\_id) | S3 bucket holding Athena query results and metadata. |
| <a name="output_table_names"></a> [table\_names](#output\_table\_names) | Raw, shape-faithful tables created in the database, keyed by log source. Prefer the views. |
| <a name="output_view_names"></a> [view\_names](#output\_view\_names) | Views a third-party data modelling application should consume, keyed by purpose. |
