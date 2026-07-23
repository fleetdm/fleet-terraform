output "byo-db" {
  value = module.byo-db
}

output "rds" {
  value = module.rds[var.active_rds_config_name]
}

output "rds_clusters" {
  description = "All named Aurora cluster module outputs."
  value       = module.rds
}

output "redis" {
  value = module.redis
}

output "secrets" {
  value = module.secrets-manager-1
}

output "rds_password_secret_kms_key_arn" {
  value = local.rds_password_secret_kms_key_arns[var.active_rds_config_name]
}

output "rds_password_secret_kms_key_arns" {
  description = "Aurora database password secret KMS key ARNs by cluster configuration name."
  value       = local.rds_password_secret_kms_key_arns
}
