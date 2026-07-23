moved {
  from = module.rds.aws_security_group_rule.default_ingress[0]
  to   = module.rds.aws_security_group_rule.this["allowed_security_group_0"]
}

moved {
  from = module.rds.aws_security_group_rule.this["allowed_security_group_0"]
  to   = aws_security_group_rule.rds_ecs_ingress["current_0"]
}

moved {
  from = module.rds.random_id.snapshot_identifier[0]
  to   = random_id.rds_final_snapshot_identifier[0]
}

moved {
  from = module.rds
  to   = module.rds["current"]
}

moved {
  from = random_password.rds
  to   = random_password.rds["current"]
}

moved {
  from = random_id.rds_final_snapshot_identifier[0]
  to   = random_id.rds_final_snapshot_identifier["current"]
}

moved {
  from = aws_db_parameter_group.main[0]
  to   = aws_db_parameter_group.main["current"]
}

moved {
  from = aws_rds_cluster_parameter_group.main[0]
  to   = aws_rds_cluster_parameter_group.main["current"]
}

moved {
  from = aws_kms_key.rds_storage[0]
  to   = aws_kms_key.rds_storage["current"]
}

moved {
  from = aws_kms_alias.rds_storage[0]
  to   = aws_kms_alias.rds_storage["current"]
}

moved {
  from = aws_kms_key.rds_password_secret[0]
  to   = aws_kms_key.rds_password_secret["current"]
}

moved {
  from = aws_kms_alias.rds_password_secret[0]
  to   = aws_kms_alias.rds_password_secret["current"]
}

moved {
  from = aws_kms_key.rds_observability[0]
  to   = aws_kms_key.rds_observability["current"]
}

moved {
  from = aws_kms_alias.rds_observability[0]
  to   = aws_kms_alias.rds_observability["current"]
}

moved {
  from = aws_kms_key.rds_cloudwatch_log_group[0]
  to   = aws_kms_key.rds_cloudwatch_log_group["current"]
}

moved {
  from = aws_kms_alias.rds_cloudwatch_log_group[0]
  to   = aws_kms_alias.rds_cloudwatch_log_group["current"]
}
