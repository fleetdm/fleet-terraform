output "fleet_extra_environment_variables" {
  value = {
    FLEET_FIREHOSE_STATUS_STREAM    = aws_kinesis_firehose_delivery_stream.osquery_status.name
    FLEET_FIREHOSE_RESULT_STREAM    = aws_kinesis_firehose_delivery_stream.osquery_results.name
    FLEET_FIREHOSE_AUDIT_STREAM     = aws_kinesis_firehose_delivery_stream.audit.name
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
