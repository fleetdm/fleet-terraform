output "byo-db" {
  value = module.byo-db
}

output "rds" {
  value = module.rds
}

output "redis" {
  value = module.redis
}

output "secrets" {
  value = module.secrets-manager-1
}

output "rds_password_secret_kms_key_arn" {
  value = local.rds_password_secret_kms_key_arn
}
