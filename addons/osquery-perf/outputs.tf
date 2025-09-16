output "osquery_perf_enroll_secret_name" {
  value = var.enroll_secret_arn != null ? null : aws_secretsmanager_secret.enroll_secret[0].name
}

output "osquery_perf_enroll_secret_id" {
  value = var.enroll_secret_arn != null ? null : aws_secretsmanager_secret.enroll_secret[0].id
}