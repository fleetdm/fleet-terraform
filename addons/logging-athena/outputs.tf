output "athena_database_name" {
  description = "Glue/Athena database holding the Fleet log tables and views."
  value       = aws_athena_database.fleet_logs.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup to point a data connector at. Its result location and encryption are enforced, so clients do not need to supply an output location."
  value       = aws_athena_workgroup.fleet_logs.name
}

output "athena_workgroup_arn" {
  description = "ARN of the Athena workgroup."
  value       = aws_athena_workgroup.fleet_logs.arn
}

output "query_results_bucket_id" {
  description = "S3 bucket holding Athena query results and metadata."
  value       = module.query_results_bucket.s3_bucket_id
}

output "query_results_bucket_arn" {
  description = "ARN of the Athena query-results bucket."
  value       = module.query_results_bucket.s3_bucket_arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the query-results bucket and the workgroup's output."
  value       = local.kms_key_arn
}

output "kms_key_alias" {
  description = "Alias of the module-created KMS key. Null when an existing key was supplied."
  value       = local.create_kms_key ? aws_kms_alias.athena[0].name : null
}

output "table_names" {
  description = "Raw, shape-faithful tables created in the database, keyed by log source. Prefer the views."
  value = {
    for k, v in {
      osquery_results = local.results_enabled ? aws_glue_catalog_table.osquery_results[0].name : null
      osquery_status  = local.status_enabled ? aws_glue_catalog_table.osquery_status[0].name : null
      fleet_audit     = local.audit_enabled ? aws_glue_catalog_table.fleet_audit[0].name : null
    } : k => v if v != null
  }
}

output "view_names" {
  description = "Views a third-party data modelling application should consume, keyed by purpose."
  value       = { for k, v in aws_glue_catalog_table.views : k => v.name }
}

output "consumer_role_arn" {
  description = "ARN of the read-only role for a third-party data modelling application. Null when consumer_role.enabled is false. Pass this into the logging module's kms_extra_policies when the log buckets are encrypted with a module-created CMK."
  value       = local.create_consumer_role ? aws_iam_role.consumer[0].arn : null
}

output "consumer_role_name" {
  description = "Name of the read-only consumer role. Null when consumer_role.enabled is false."
  value       = local.create_consumer_role ? aws_iam_role.consumer[0].name : null
}
