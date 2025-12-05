output "fleet_extra_environment_variables" {
  value = merge(
    {
      FLEET_FIREHOSE_REGION = data.aws_region.current.region
    },
    # Status: stream + plugin only if "status" exists
    try({
      FLEET_FIREHOSE_STATUS_STREAM    = aws_kinesis_firehose_delivery_stream.splunk["status"].name
      FLEET_OSQUERY_STATUS_LOG_PLUGIN = "firehose"
    }, {}),
    # Results: stream + plugin only if "results" exists
    try({
      FLEET_FIREHOSE_RESULT_STREAM    = aws_kinesis_firehose_delivery_stream.splunk["results"].name
      FLEET_OSQUERY_RESULT_LOG_PLUGIN = "firehose"
    }, {}),
    # Audit: stream + plugin + enable flag only if "audit" exists
    try({
      FLEET_FIREHOSE_AUDIT_STREAM     = aws_kinesis_firehose_delivery_stream.splunk["audit"].name
      FLEET_ACTIVITY_AUDIT_LOG_PLUGIN = "firehose"
      FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
    }, {})
  )
  description = "Environment variables to configure Fleet to use Splunk logging via Firehose"
}


output "fleet_extra_iam_policies" {
  value = [
    aws_iam_policy.firehose-logging.arn
  ]
  description = "IAM policies required for Fleet to log to Splunk via Firehose"
}

output "fleet_s3_splunk_failure_config" {
  value = {
    bucket_name      = aws_s3_bucket.splunk-failure.bucket
    s3_object_prefix = var.s3_bucket_config.name_prefix
  }
  description = "S3 bucket details - splunk-failure"
}
