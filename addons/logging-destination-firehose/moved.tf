# ── Migration: legacy 3-bucket resources → new for_each resources ─────────────
# These moved blocks allow existing deployments to upgrade to this module
# version with zero data loss. Terraform will rename the resources in state
# rather than destroying and recreating them.
#
# After running `terraform plan` with these moves, the resources are
# re-parented under the new for_each addresses. No AWS objects are changed.

# S3 Buckets
moved {
  from = aws_s3_bucket.osquery-results
  to   = aws_s3_bucket.destination["results"]
}

moved {
  from = aws_s3_bucket.osquery-status
  to   = aws_s3_bucket.destination["status"]
}

moved {
  from = aws_s3_bucket.audit
  to   = aws_s3_bucket.destination["audit"]
}

# S3 Bucket Lifecycle Configurations
moved {
  from = aws_s3_bucket_lifecycle_configuration.osquery-results
  to   = aws_s3_bucket_lifecycle_configuration.destination["results"]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.osquery-status
  to   = aws_s3_bucket_lifecycle_configuration.destination["status"]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.audit
  to   = aws_s3_bucket_lifecycle_configuration.destination["audit"]
}

# S3 Bucket Server-Side Encryption Configurations
moved {
  from = aws_s3_bucket_server_side_encryption_configuration.osquery-results
  to   = aws_s3_bucket_server_side_encryption_configuration.destination["results"]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.osquery-status
  to   = aws_s3_bucket_server_side_encryption_configuration.destination["status"]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.audit
  to   = aws_s3_bucket_server_side_encryption_configuration.destination["audit"]
}

# S3 Bucket Public Access Blocks
moved {
  from = aws_s3_bucket_public_access_block.osquery-results
  to   = aws_s3_bucket_public_access_block.destination["results"]
}

moved {
  from = aws_s3_bucket_public_access_block.osquery-status
  to   = aws_s3_bucket_public_access_block.destination["status"]
}

moved {
  from = aws_s3_bucket_public_access_block.audit
  to   = aws_s3_bucket_public_access_block.destination["audit"]
}

# S3 Bucket Policies (deny insecure transport)
moved {
  from = aws_s3_bucket_policy.deny_insecure_transport_osquery_results
  to   = aws_s3_bucket_policy.deny_insecure_transport["results"]
}

moved {
  from = aws_s3_bucket_policy.deny_insecure_transport_osquery_status
  to   = aws_s3_bucket_policy.deny_insecure_transport["status"]
}

moved {
  from = aws_s3_bucket_policy.deny_insecure_transport_audit
  to   = aws_s3_bucket_policy.deny_insecure_transport["audit"]
}

# Firehose IAM Policies
moved {
  from = aws_iam_policy.firehose-results
  to   = aws_iam_policy.firehose["results"]
}

moved {
  from = aws_iam_policy.firehose-status
  to   = aws_iam_policy.firehose["status"]
}

moved {
  from = aws_iam_policy.firehose-audit
  to   = aws_iam_policy.firehose["audit"]
}

# Firehose IAM Roles
moved {
  from = aws_iam_role.firehose-results
  to   = aws_iam_role.firehose["results"]
}

moved {
  from = aws_iam_role.firehose-status
  to   = aws_iam_role.firehose["status"]
}

moved {
  from = aws_iam_role.firehose-audit
  to   = aws_iam_role.firehose["audit"]
}

# Firehose IAM Role Policy Attachments
moved {
  from = aws_iam_role_policy_attachment.firehose-results
  to   = aws_iam_role_policy_attachment.firehose["results"]
}

moved {
  from = aws_iam_role_policy_attachment.firehose-status
  to   = aws_iam_role_policy_attachment.firehose["status"]
}

moved {
  from = aws_iam_role_policy_attachment.firehose-audit
  to   = aws_iam_role_policy_attachment.firehose["audit"]
}

# Firehose Delivery Streams
moved {
  from = aws_kinesis_firehose_delivery_stream.osquery_results
  to   = aws_kinesis_firehose_delivery_stream.fleet_log_destinations["results"]
}

moved {
  from = aws_kinesis_firehose_delivery_stream.osquery_status
  to   = aws_kinesis_firehose_delivery_stream.fleet_log_destinations["status"]
}

moved {
  from = aws_kinesis_firehose_delivery_stream.audit
  to   = aws_kinesis_firehose_delivery_stream.fleet_log_destinations["audit"]
}

