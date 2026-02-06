output "log_destination_arn" {
  description = "CloudWatch Logs destination ARN to use from the source account module."
  value       = aws_cloudwatch_log_destination.destination.arn
}

output "log_destination_name" {
  description = "CloudWatch Logs destination name."
  value       = aws_cloudwatch_log_destination.destination.name
}

output "destination_region" {
  description = "Region where the CloudWatch Logs destination was created. This must match the source log group region."
  value       = data.aws_region.destination.name
}

output "destination_account_id" {
  description = "AWS account ID where the CloudWatch Logs destination exists."
  value       = data.aws_caller_identity.destination.account_id
}

output "destination_role_arn" {
  description = "IAM role ARN assumed by CloudWatch Logs to write records into Firehose."
  value       = aws_iam_role.destination.arn
}

output "firehose_delivery_stream_name" {
  description = "Firehose delivery stream name used as CloudWatch Logs destination target."
  value       = aws_kinesis_firehose_delivery_stream.destination.name
}

output "firehose_delivery_stream_arn" {
  description = "Firehose delivery stream ARN used as CloudWatch Logs destination target."
  value       = aws_kinesis_firehose_delivery_stream.destination.arn
}

output "firehose_region" {
  description = "Region where the Firehose delivery stream was created."
  value       = data.aws_region.target.name
}

output "s3_bucket_name" {
  description = "S3 bucket name used as Firehose destination."
  value       = aws_s3_bucket.destination.bucket
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN used as Firehose destination."
  value       = aws_s3_bucket.destination.arn
}
