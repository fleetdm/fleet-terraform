moved {
  from = module.rds.aws_security_group_rule.default_ingress[0]
  to   = module.rds.aws_security_group_rule.this["allowed_security_group_0"]
}

moved {
  from = module.rds.random_id.snapshot_identifier[0]
  to   = random_id.rds_final_snapshot_identifier[0]
}
