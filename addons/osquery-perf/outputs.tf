output "osquery_perf_enroll_secret_name" {
    value = aws_secretsmanager_secret.enroll_secret.name
}

output "osquery_perf_enroll_secret_id" {
    value = aws_secretsmanager_secret.enroll_secret.id
}