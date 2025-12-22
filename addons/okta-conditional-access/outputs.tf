output "redirect_rules" {
  value = {
    actions = [{
      redirect = {
        host        = "${var.alb_config.subdomain_prefix}.#{host}"
        path        = "/api/fleet/conditional_access/idp/sso"
        protocol    = "HTTPS"
        status_code = "HTTP_302"
      }
    }]
    conditions = [{
      path_pattern = {
        values = ["/api/fleet/conditional_access/idp/sso"]
      }
    }]
    priority = 1
  }
}

output "lb_trust_store__bucket" {
  value = module.lb_trust_store_bucket
}

output "alb" {
  value = merge(module.okta_mtls_alb, {
    lb_dns_name               = module.okta_mtls_alb.dns_name
    lb_zone_id                = module.okta_mtls_alb.zone_id
    target_group_names        = [for k, tg in module.okta_mtls_alb.target_groups : tg.name]
    target_group_arn_suffixes = [for k, tg in module.okta_mtls_alb.target_groups : tg.arn_suffix]
    target_group_arns         = [for k, tg in module.okta_mtls_alb.target_groups : tg.arn]
    lb_arn_suffix             = module.okta_mtls_alb.arn_suffix
  })
}

output "alb_security_group" {
  value = aws_security_group.alb
}
