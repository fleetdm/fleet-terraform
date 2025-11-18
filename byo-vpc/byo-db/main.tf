locals {
  mtls_subdomain_defaults = {
    okta = {
      enabled       = false
      domain_prefix = "okta"
    }
    my_device = {
      enabled       = false
      domain_prefix = "my-device"
    }
  }
  provided_mtls_subdomains = coalesce(var.alb_config.mtls_subdomains, {})
  mtls_subdomains = {
    for key, defaults in local.mtls_subdomain_defaults :
    key => merge(defaults, lookup(local.provided_mtls_subdomains, key, defaults))
  }
  mtls_subdomain_labels = { for key in keys(local.mtls_subdomains) :
    key => replace(key, "_", "-")
  }
  okta_special_path = "/api/fleet/conditional_access/idp/sso"
  my_device_path_sets = [
    [
      "/device/*",
      "/api/*/fleet/device/*",
      "/assets/*",
    ],
    [
      "/api/*/fleet/device/*/migrate_mdm",
      "/api/*/fleet/device/*/rotate_encryption_key",
    ],
    [
      "/api/*/fleet/device/*/debug/errors",
      "/api/*/fleet/device/*/desktop",
    ],
    [
      "/api/*/fleet/device/*/refetch",
      "/api/*/fleet/device/*/transparency",
      "/api/fleet/device/ping",
    ],
  ]
  fleet_config = merge(var.fleet_config, {
    loadbalancer = {
      arn = module.alb.target_groups["tg-0"].arn
    },
    networking = merge(var.fleet_config.networking, {
      subnets         = var.fleet_config.networking.subnets
      security_groups = var.fleet_config.networking.security_groups
      ingress_sources = {
        cidr_blocks      = var.fleet_config.networking.ingress_sources.cidr_blocks
        ipv6_cidr_blocks = var.fleet_config.networking.ingress_sources.ipv6_cidr_blocks
        security_groups  = concat(var.fleet_config.networking.ingress_sources.security_groups, [module.alb.security_group_id])
        prefix_list_ids  = var.fleet_config.networking.ingress_sources.prefix_list_ids
      }
    })
  })
  fleet_target_group = [
    {
      name              = var.alb_config.name
      backend_protocol  = "HTTP"
      backend_port      = 80
      target_type       = "ip"
      create_attachment = false
      health_check = {
        path                = "/healthz"
        matcher             = "200"
        timeout             = 10
        interval            = 15
        healthy_threshold   = 5
        unhealthy_threshold = 5
      }
    }
  ]
  target_group_sources = concat(local.fleet_target_group, coalesce(var.alb_config.extra_target_groups, []))
  target_groups = { for idx, tg in local.target_group_sources :
    "tg-${idx}" => merge(tg, {
      create_attachment = try(tg.create_attachment, false)
    })
  }
  enabled_mtls_subdomains = [
    for subdomain, config in local.mtls_subdomains : subdomain if config.enabled
  ]
  mtls_domain_prefixes = {
    for subdomain, config in local.mtls_subdomains :
    subdomain => coalesce(config.domain_prefix, local.mtls_subdomain_labels[subdomain])
  }
  mtls_host_patterns = {
    for subdomain, prefix in local.mtls_domain_prefixes :
    subdomain => ["^${replace(prefix, ".", "\\.")}.*"]
  }
  mtls_okta_forward_rule = local.mtls_subdomains["okta"].enabled ? [{
    key = "${local.mtls_subdomain_labels["okta"]}-domain"
    conditions = [
      {
        host_header = {
          regex_values = local.mtls_host_patterns["okta"]
        }
      },
      {
        path_pattern = {
          values = [local.okta_special_path]
        }
      }
    ]
    actions = [{
      type             = "forward"
      target_group_key = "tg-0"
    }]
  }] : []
  mtls_okta_deny_rule = local.mtls_subdomains["okta"].enabled ? [{
    key = "${local.mtls_subdomain_labels["okta"]}-deny"
    conditions = [{
      host_header = {
        regex_values = local.mtls_host_patterns["okta"]
      }
    }]
    actions = [{
      type         = "fixed-response"
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }]
  }] : []
  mtls_okta_redirect_rule = local.mtls_subdomains["okta"].enabled ? [{
    key = "${local.mtls_subdomain_labels["okta"]}-redirect"
    conditions = [{
      path_pattern = {
        values = [local.okta_special_path]
      }
    }]
    actions = [{
      type        = "redirect"
      host        = "${local.mtls_domain_prefixes["okta"]}.#{host}"
      path        = local.okta_special_path
      protocol    = "HTTPS"
      status_code = "HTTP_302"
    }]
  }] : []
  mtls_my_device_forward_rules = local.mtls_subdomains["my_device"].enabled ? [
    for idx, paths in local.my_device_path_sets : {
      key = "${local.mtls_subdomain_labels["my_device"]}-paths-${idx}"
      conditions = [
        {
          host_header = {
            regex_values = local.mtls_host_patterns["my_device"]
          }
        },
        {
          path_pattern = {
            values = paths
          }
        }
      ]
      actions = [{
        type             = "forward"
        target_group_key = "tg-0"
      }]
    }
  ] : []
  mtls_my_device_deny_rule = local.mtls_subdomains["my_device"].enabled ? [{
    key = "${local.mtls_subdomain_labels["my_device"]}-deny"
    conditions = [{
      host_header = {
        regex_values = local.mtls_host_patterns["my_device"]
      }
    }]
    actions = [{
      type         = "fixed-response"
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }]
  }] : []
  mtls_my_device_redirect_rule = local.mtls_subdomains["my_device"].enabled ? [{
    key = "${local.mtls_subdomain_labels["my_device"]}-redirect"
    conditions = [{
      path_pattern = {
        values = ["/device/*"]
      }
    }]
    actions = [{
      type        = "redirect"
      host        = "${local.mtls_domain_prefixes["my_device"]}.#{host}"
      protocol    = "HTTPS"
      status_code = "HTTP_302"
    }]
  }] : []
  mtls_rule_sequence = concat(
    local.mtls_okta_forward_rule,
    local.mtls_okta_deny_rule,
    local.mtls_okta_redirect_rule,
    local.mtls_my_device_forward_rules,
    local.mtls_my_device_deny_rule,
    local.mtls_my_device_redirect_rule,
  )
  mtls_domain_rules = {
    for idx, rule in local.mtls_rule_sequence :
    rule.key => merge(rule, { priority = idx + 1 })
  }
}

module "ecs" {
  source           = "./byo-ecs"
  ecs_cluster      = module.cluster.cluster_name
  fleet_config     = local.fleet_config
  migration_config = var.migration_config
  vpc_id           = var.vpc_id
}

module "cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "4.1.2"

  autoscaling_capacity_providers        = var.ecs_cluster.autoscaling_capacity_providers
  cluster_configuration                 = var.ecs_cluster.cluster_configuration
  cluster_name                          = var.ecs_cluster.cluster_name
  cluster_settings                      = var.ecs_cluster.cluster_settings
  create                                = var.ecs_cluster.create
  default_capacity_provider_use_fargate = var.ecs_cluster.default_capacity_provider_use_fargate
  fargate_capacity_providers            = var.ecs_cluster.fargate_capacity_providers
  tags                                  = var.ecs_cluster.tags
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.2.0"

  name = var.alb_config.name

  load_balancer_type = "application"

  vpc_id                     = var.vpc_id
  subnets                    = var.alb_config.subnets
  security_groups            = concat(var.alb_config.security_groups, [aws_security_group.alb.id])
  access_logs                = var.alb_config.access_logs
  idle_timeout               = var.alb_config.idle_timeout
  internal                   = var.alb_config.internal
  enable_deletion_protection = var.alb_config.enable_deletion_protection

  target_groups = local.target_groups

  xff_header_processing_mode = var.alb_config.xff_header_processing_mode

  listeners = {
    http = {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = merge({
      # Require TLS 1.2 as earlier versions are insecure
      ssl_policy      = var.alb_config.tls_policy
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = var.alb_config.certificate_arn
      mutual_authentication = {
        mode = "passthrough"
      }
      forward = {
        target_group_key = "tg-0"
      }
      routing_http_request_x_amzn_mtls_clientcert_serial_number_header_name = "X-Client-Cert-Serial"
      rules = merge(local.mtls_domain_rules, { for idx, rule in var.alb_config.https_listener_rules :
        "rule-${idx}" => merge(rule, {
          conditions = flatten([
            for condition in rule.conditions : concat(flatten([
              for key in ["host_headers", "http_request_methods", "path_patterns", "source_ips"] :
              lookup(condition, key, null) != null ? [{
                "${trimsuffix(key, "s")}" = {
                  values = condition[key]
                }
              }] : []
              ]),
              lookup(condition, "http_headers", null) != null ? [
                for header in condition.http_headers : {
                  http_header = {
                    http_header_name = header.http_header_name
                    values           = header.values
                  }
              }] : [],
              lookup(condition, "query_strings", null) != null ? [{
                query_string = [
                  for qs in condition.query_strings : {
                    key   = qs.key
                    value = qs.value
                  }
                ]
              }] : [],
          )])
          actions = [for action in rule.actions : merge(action, {
            target_group_key = try(action.target_group_key, try("tg-${action.target_group_index}", null))
          })]
        })
      })
    }, var.alb_config.https_overrides)
  }
  tags = {
    Name = var.alb_config.name
  }
}

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:False positive
  vpc_id      = var.vpc_id
  description = "Fleet ALB Security Group"
  ingress {
    description      = "Ingress from all, its a public load balancer"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = var.alb_config.allowed_cidrs
    ipv6_cidr_blocks = var.alb_config.allowed_ipv6_cidrs
  }

  ingress {
    description      = "For http to https redirect"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = var.alb_config.allowed_cidrs
    ipv6_cidr_blocks = var.alb_config.allowed_ipv6_cidrs
  }

  egress {
    description      = "Egress to all"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = var.alb_config.egress_cidrs
    ipv6_cidr_blocks = var.alb_config.egress_ipv6_cidrs
  }
}
