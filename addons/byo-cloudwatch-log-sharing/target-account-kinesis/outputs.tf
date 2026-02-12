output "log_destination" {
  description = "CloudWatch Logs destination details to share with the source-account team."
  value = {
    arn        = aws_cloudwatch_log_destination.destination.arn
    name       = aws_cloudwatch_log_destination.destination.name
    region     = data.aws_region.destination.region
    account_id = data.aws_caller_identity.destination.account_id
    role_arn   = aws_iam_role.destination.arn
  }
}

output "kinesis" {
  description = "Kinesis destination details."
  value = {
    stream_name = aws_kinesis_stream.destination.name
    stream_arn  = aws_kinesis_stream.destination.arn
    region      = data.aws_region.target.region
  }
}
