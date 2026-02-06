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
  description = "IAM role ARN assumed by CloudWatch Logs to write records into Kinesis."
  value       = aws_iam_role.destination.arn
}

output "kinesis_stream_name" {
  description = "Kinesis stream name used as CloudWatch Logs destination target."
  value       = aws_kinesis_stream.destination.name
}

output "kinesis_stream_arn" {
  description = "Kinesis stream ARN used as CloudWatch Logs destination target."
  value       = aws_kinesis_stream.destination.arn
}

output "kinesis_region" {
  description = "Region where the Kinesis stream was created."
  value       = data.aws_region.target.name
}
