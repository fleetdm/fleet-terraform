output "fleet_extra_environment_variables" {
  value = {
    FLEET_FIREHOSE_STATUS_STREAM    = aws_kinesis_firehose_delivery_stream.snowflake["status"].name
    FLEET_FIREHOSE_RESULT_STREAM    = aws_kinesis_firehose_delivery_stream.snowflake["results"].name
    FLEET_FIREHOSE_AUDIT_STREAM     = aws_kinesis_firehose_delivery_stream.snowflake["audit"].name
    FLEET_FIREHOSE_REGION           = data.aws_region.current.region
    FLEET_OSQUERY_STATUS_LOG_PLUGIN = "firehose"
    FLEET_OSQUERY_RESULT_LOG_PLUGIN = "firehose"
    FLEET_ACTIVITY_AUDIT_LOG_PLUGIN = "firehose"
    FLEET_ACTIVITY_ENABLE_AUDIT_LOG = "true"
  }
  description = "Environment variables to configure Fleet to use Snowflake logging via Firehose"
}

output "fleet_extra_iam_policies" {
  value = [
    aws_iam_policy.firehose-logging.arn
  ]
  description = "IAM policies required for Fleet to log to Snowflake via Firehose"
}
