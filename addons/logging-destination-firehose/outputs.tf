output "fleet_extra_environment_variables" {
  value = {
    FLEET_FIREHOSE_STATUS_STREAM    = aws_kinesis_firehose_delivery_stream.fleet_log_destinations[var.fleet_firehose_status_stream_key].name
    FLEET_FIREHOSE_RESULT_STREAM    = aws_kinesis_firehose_delivery_stream.fleet_log_destinations[var.fleet_firehose_result_stream_key].name
    FLEET_FIREHOSE_AUDIT_STREAM     = aws_kinesis_firehose_delivery_stream.fleet_log_destinations[var.fleet_firehose_audit_stream_key].name
    FLEET_FIREHOSE_REGION           = data.aws_region.current.region
    FLEET_OSQUERY_STATUS_LOG_PLUGIN = "firehose"
    FLEET_OSQUERY_RESULT_LOG_PLUGIN = "firehose"
    FLEET_ACTIVITY_AUDIT_LOG_PLUGIN = "firehose"
    FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
  }
}

output "fleet_extra_iam_policies" {
  value = [
    aws_iam_policy.firehose-logging.arn
  ]
}

output "fleet_s3_firehose_config" {
  value = {
    for bk in local.bucket_keys : bk => {
      bucket_name = aws_s3_bucket.destination[bk].bucket
    }
  }
  description = "S3 bucket details for Firehose delivery, keyed by bucket key."
}

output "log_destinations" {
  description = "Map of Firehose delivery stream names."
  value       = { for key, stream in aws_kinesis_firehose_delivery_stream.fleet_log_destinations : key => stream.name }
}
