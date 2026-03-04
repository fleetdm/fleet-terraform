output "log_s3_bucket_id" {
  description = "SSE-S3 landing bucket used by ALB access logging"
  value       = module.s3_bucket_for_logs.s3_bucket_id
}

output "archive_log_s3_bucket_id" {
  description = "SSE-KMS archive bucket used for retained ALB logs and Athena table data"
  value       = aws_s3_bucket.logs_archive.id
}
