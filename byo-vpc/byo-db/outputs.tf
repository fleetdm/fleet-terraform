output "byo-ecs" {
  value = module.ecs
}

output "cluster" {
  value = module.cluster
}

output "alb" {
  value = merge(module.alb, {
    lb_dns_name               = module.alb.dns_name
    lb_zone_id                = module.alb.zone_id
    target_group_names        = [for k, tg in module.alb.target_groups : tg.name]
    target_group_arn_suffixes = [for k, tg in module.alb.target_groups : tg.arn_suffix]
    target_group_arns         = [for k, tg in module.alb.target_groups : tg.arn]
    lb_arn_suffix             = module.alb.arn_suffix
  })
}

output "mtls_albs" {
  value = {
    for name, alb in module.mtls_albs :
    name => merge(alb, {
      lb_dns_name               = alb.dns_name
      lb_zone_id                = alb.zone_id
      target_group_names        = [for _, tg in alb.target_groups : tg.name]
      target_group_arn_suffixes = [for _, tg in alb.target_groups : tg.arn_suffix]
      target_group_arns         = [for _, tg in alb.target_groups : tg.arn]
      lb_arn_suffix             = alb.arn_suffix
    })
  }
}
