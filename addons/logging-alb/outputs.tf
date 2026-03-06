output "log_s3_bucket_id" {
  description = "S3 bucket used by ALB access logging (SSE-S3 on write, re-encrypted to SSE-KMS by Lambda)"
  value       = module.s3_bucket_for_logs.s3_bucket_id
}
