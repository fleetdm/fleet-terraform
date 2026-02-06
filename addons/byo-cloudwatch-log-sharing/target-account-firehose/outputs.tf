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

output "firehose" {
  description = "Firehose destination details."
  value = {
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.destination.name
    delivery_stream_arn  = aws_kinesis_firehose_delivery_stream.destination.arn
    region               = data.aws_region.target.region
  }
}

output "s3_bucket" {
  description = "S3 bucket details used as the Firehose destination."
  value = {
    name = aws_s3_bucket.destination.bucket
    arn  = aws_s3_bucket.destination.arn
  }
}
