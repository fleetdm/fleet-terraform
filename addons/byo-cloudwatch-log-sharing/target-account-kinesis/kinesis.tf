resource "aws_kinesis_stream" "destination" {
  provider         = aws.target
  name             = var.kinesis.stream_name
  retention_period = var.kinesis.retention_period
  shard_count      = var.kinesis.stream_mode == "PROVISIONED" ? var.kinesis.shard_count : null

  stream_mode_details {
    stream_mode = var.kinesis.stream_mode
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.destination.account_id == data.aws_caller_identity.target.account_id
      error_message = "aws.destination and aws.target providers must use the same AWS account."
    }
  }
}
