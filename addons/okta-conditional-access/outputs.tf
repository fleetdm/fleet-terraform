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
