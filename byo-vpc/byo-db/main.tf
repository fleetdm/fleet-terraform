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
        security_groups  = concat(var.fleet_config.networking.ingress_sources.security_groups, local.load_balancer_security_group_ids)
        prefix_list_ids  = var.fleet_config.networking.ingress_sources.prefix_list_ids
      }
    })
    extra_load_balancers = concat(coalesce(var.fleet_config.extra_load_balancers, []), local.mtls_fleet_extra_load_balancers)
  })
  fleet_target_group_defaults = {
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
  fleet_target_group = [
    merge(local.fleet_target_group_defaults, {
      name = var.alb_config.name
    })
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
  mtls_target_group_sources = {
    for subdomain in local.enabled_mtls_subdomains :
    subdomain => [
      merge(local.fleet_target_group_defaults, {
        name = "${var.alb_config.name}-${local.mtls_subdomain_labels[subdomain]}"
      })
    ]
  }
  mtls_target_groups = {
    for subdomain, target_groups in local.mtls_target_group_sources :
    subdomain => {
      for idx, tg in target_groups :
      "tg-${idx}" => merge(tg, {
        create_attachment = try(tg.create_attachment, false)
      })
    }
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
      forward = {
        target_group_key = "tg-0"
      }
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
      fixed_response = {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
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
      redirect = {
        host        = "${local.mtls_domain_prefixes["okta"]}.#{host}"
        path        = local.okta_special_path
        protocol    = "HTTPS"
        status_code = "HTTP_302"
      }
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
        forward = {
          target_group_key = "tg-0"
        }
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
      fixed_response = {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }]
  }] : []
  mtls_my_device_redirect_rule = local.mtls_subdomains["my_device"].enabled ? [{
    key = "${local.mtls_subdomain_labels["my_device"]}-redirect"
    conditions = [{
      # Only for iOS/iPadOS devices
      path_pattern = {
        regex_values = ["^/device/([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})(/|$)"]
      }
    }]
    actions = [{
      redirect = {
        host        = "${local.mtls_domain_prefixes["my_device"]}.#{host}"
        protocol    = "HTTPS"
        status_code = "HTTP_302"
      }
    }]
  }] : []
  mtls_redirect_rule_sequence = concat(
    local.mtls_okta_redirect_rule,
    local.mtls_my_device_redirect_rule,
  )
  mtls_load_balancer_rule_sequences = {
    okta      = concat(local.mtls_okta_forward_rule, local.mtls_okta_deny_rule)
    my_device = concat(local.mtls_my_device_forward_rules, local.mtls_my_device_deny_rule)
  }
  listener_action_keys = [
    "forward",
    "fixed_response",
    "redirect",
    "weighted_forward",
    "authenticate_cognito",
    "authenticate_oidc",
  ]
  listener_condition_keys = [
    "host_header",
    "http_header",
    "http_request_method",
    "path_pattern",
    "query_string",
    "source_ip",
  ]
  listener_condition_defaults = {
    host_header         = null
    http_header         = null
    http_request_method = null
    path_pattern        = null
    query_string        = null
    source_ip           = null
  }
  listener_action_defaults = {
    order                = null
    authenticate_cognito = null
    authenticate_oidc    = null
    fixed_response       = null
    forward              = null
    weighted_forward     = null
    redirect             = null
  }
  mtls_redirect_rules = {
    for idx, rule in local.mtls_redirect_rule_sequence :
    rule.key => merge(
      {
        priority = idx + 1
      },
      {
        for k, v in rule : k => v if k != "key"
      },
      {
        conditions = [
          for condition in coalesce(rule.conditions, []) :
          merge(local.listener_condition_defaults, condition)
        ]
        actions = [
          for action in coalesce(rule.actions, []) :
          merge(local.listener_action_defaults, action)
        ]
      }
    )
  }
  mtls_load_balancer_rules = {
    for subdomain, sequence in local.mtls_load_balancer_rule_sequences :
    subdomain => {
      for idx, rule in sequence :
      rule.key => merge(
        {
          priority = idx + 1
        },
        {
          for k, v in rule : k => v if k != "key"
        },
        {
          conditions = [
            for condition in coalesce(rule.conditions, []) :
            merge(local.listener_condition_defaults, condition)
          ]
          actions = [
            for action in coalesce(rule.actions, []) :
            merge(local.listener_action_defaults, action)
          ]
        }
      )
    }
    if contains(local.enabled_mtls_subdomains, subdomain)
  }
  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
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
      forward = {
        target_group_key = "tg-0"
      }
      rules = merge(local.mtls_redirect_rules, { for idx, rule in var.alb_config.https_listener_rules :
        "rule-${idx}" => merge({
          for k, v in rule :
          k => v if k != "key"
          }, {
          conditions = [
            for normalized_condition in flatten([
              for condition in coalesce(rule.conditions, []) :
              concat(
                length([
                  for key in local.listener_condition_keys : key
                  if contains(keys(condition), key)
                  ]) > 0 ? [{
                  for key in local.listener_condition_keys :
                  key => lookup(condition, key, null)
                }] : [],
                flatten([
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
                }] : []
              )
            ]) : merge(local.listener_condition_defaults, normalized_condition)
          ]
          actions = [
            for action in coalesce(rule.actions, []) :
            merge(
              local.listener_action_defaults,
              length([
                for key in local.listener_action_keys : key
                if contains(keys(action), key)
              ]) > 0 ?
              merge(
                { for k, v in { order = lookup(action, "order", null) } : k => v if v != null },
                contains(keys(action), "forward") ? {
                  forward = merge(
                    { for k, v in try(action.forward, {}) : k => v if k != "target_group_index" },
                    {
                      for k, v in {
                        target_group_key = coalesce(
                          try(action.forward.target_group_key, null),
                          try("tg-${action.forward.target_group_index}", null)
                        )
                      } : k => v if v != null
                    }
                  )
                } : {},
                contains(keys(action), "weighted_forward") ? {
                  weighted_forward = merge(
                    {
                      for k, v in try(action.weighted_forward, {}) :
                      k => v if k != "target_groups"
                    },
                    try(action.weighted_forward.target_groups, null) != null ? {
                      target_groups = [
                        for target_group in try(action.weighted_forward.target_groups, []) : merge(
                          {
                            for k, v in target_group :
                            k => v if k != "target_group_index"
                          },
                          {
                            for k, v in {
                              target_group_key = coalesce(
                                try(target_group.target_group_key, null),
                                try("tg-${target_group.target_group_index}", null)
                              )
                            } : k => v if v != null
                          }
                        )
                      ]
                    } : {}
                  )
                } : {},
                contains(keys(action), "fixed_response") ? {
                  fixed_response = action.fixed_response
                } : {},
                contains(keys(action), "redirect") ? {
                  redirect = action.redirect
                } : {},
                contains(keys(action), "authenticate_cognito") ? {
                  authenticate_cognito = action.authenticate_cognito
                } : {},
                contains(keys(action), "authenticate_oidc") ? {
                  authenticate_oidc = action.authenticate_oidc
                } : {}
              ) :
              merge(
                { for k, v in { order = lookup(action, "order", null) } : k => v if v != null },
                lower(lookup(action, "type", "")) == "forward" ? {
                  forward = {
                    for k, v in {
                      target_group_arn = lookup(action, "target_group_arn", null)
                      target_group_key = coalesce(
                        lookup(action, "target_group_key", null),
                        try("tg-${action.target_group_index}", null)
                      )
                    } : k => v if v != null
                  }
                } : {},
                lower(lookup(action, "type", "")) == "weighted-forward" ? {
                  weighted_forward = merge(
                    {
                      for k, v in {
                        stickiness = lookup(action, "stickiness", null)
                      } : k => v if v != null
                    },
                    lookup(action, "target_groups", null) != null ? {
                      target_groups = [
                        for target_group in action.target_groups : merge(
                          {
                            for k, v in target_group :
                            k => v if k != "target_group_index"
                          },
                          {
                            for k, v in {
                              target_group_key = coalesce(
                                lookup(target_group, "target_group_key", null),
                                try("tg-${target_group.target_group_index}", null)
                              )
                            } : k => v if v != null
                          }
                        )
                      ]
                    } : {}
                  )
                } : {},
                lower(lookup(action, "type", "")) == "fixed-response" ? {
                  fixed_response = {
                    for k, v in {
                      content_type = lookup(action, "content_type", null)
                      message_body = lookup(action, "message_body", null)
                      status_code  = lookup(action, "status_code", null)
                    } : k => v if v != null
                  }
                } : {},
                lower(lookup(action, "type", "")) == "redirect" ? {
                  redirect = {
                    for k, v in {
                      host        = lookup(action, "host", null)
                      path        = lookup(action, "path", null)
                      port        = lookup(action, "port", null)
                      protocol    = lookup(action, "protocol", null)
                      query       = lookup(action, "query", null)
                      status_code = lookup(action, "status_code", null)
                    } : k => v if v != null
                  }
                } : {},
                lower(lookup(action, "type", "")) == "authenticate-cognito" ? {
                  authenticate_cognito = {
                    for k, v in {
                      authentication_request_extra_params = lookup(action, "authentication_request_extra_params", null)
                      on_unauthenticated_request          = lookup(action, "on_unauthenticated_request", null)
                      scope                               = lookup(action, "scope", null)
                      session_cookie_name                 = lookup(action, "session_cookie_name", null)
                      session_timeout                     = lookup(action, "session_timeout", null)
                      user_pool_arn                       = lookup(action, "user_pool_arn", null)
                      user_pool_client_id                 = lookup(action, "user_pool_client_id", null)
                      user_pool_domain                    = lookup(action, "user_pool_domain", null)
                    } : k => v if v != null
                  }
                } : {},
                lower(lookup(action, "type", "")) == "authenticate-oidc" ? {
                  authenticate_oidc = {
                    for k, v in {
                      authentication_request_extra_params = lookup(action, "authentication_request_extra_params", null)
                      authorization_endpoint              = lookup(action, "authorization_endpoint", null)
                      client_id                           = lookup(action, "client_id", null)
                      client_secret                       = lookup(action, "client_secret", null)
                      issuer                              = lookup(action, "issuer", null)
                      on_unauthenticated_request          = lookup(action, "on_unauthenticated_request", null)
                      scope                               = lookup(action, "scope", null)
                      session_cookie_name                 = lookup(action, "session_cookie_name", null)
                      session_timeout                     = lookup(action, "session_timeout", null)
                      token_endpoint                      = lookup(action, "token_endpoint", null)
                      user_info_endpoint                  = lookup(action, "user_info_endpoint", null)
                    } : k => v if v != null
                  }
                } : {}
              )
            )
          ]
        })
      })
    }, var.alb_config.https_overrides)
  }
  mtls_load_balancer_listeners = {
    for subdomain in local.enabled_mtls_subdomains :
    subdomain => {
      http = {
        port     = 80
        protocol = "HTTP"
        redirect = {
          port        = "443"
          protocol    = "HTTPS"
          status_code = "HTTP_301"
        }
      }
      https = {
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
        rules                                                                 = lookup(local.mtls_load_balancer_rules, subdomain, {})
      }
    }
  }
  mtls_load_balancers = {
    for subdomain in local.enabled_mtls_subdomains :
    subdomain => {
      name          = "${var.alb_config.name}-${local.mtls_subdomain_labels[subdomain]}"
      listeners     = local.mtls_load_balancer_listeners[subdomain]
      target_groups = local.mtls_target_groups[subdomain]
    }
  }
  mtls_fleet_extra_load_balancers = flatten([
    for alb in values(module.mtls_albs) : [
      for _, target_group in alb.target_groups : {
        target_group_arn = target_group.arn
        container_name   = "fleet"
        container_port   = 8080
      }
    ]
  ])
  load_balancer_security_group_ids = compact(concat(
    [module.alb.security_group_id],
    [for alb in values(module.mtls_albs) : alb.security_group_id]
  ))
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

  listeners = local.listeners

  tags = {
    Name = var.alb_config.name
  }
}

module "mtls_albs" {
  for_each = local.mtls_load_balancers

  source  = "terraform-aws-modules/alb/aws"
  version = "10.2.0"

  name = each.value.name

  load_balancer_type = "application"

  vpc_id                     = var.vpc_id
  subnets                    = var.alb_config.subnets
  security_groups            = concat(var.alb_config.security_groups, [aws_security_group.alb.id])
  access_logs                = var.alb_config.access_logs
  idle_timeout               = var.alb_config.idle_timeout
  internal                   = var.alb_config.internal
  enable_deletion_protection = var.alb_config.enable_deletion_protection

  target_groups = each.value.target_groups

  xff_header_processing_mode = var.alb_config.xff_header_processing_mode

  listeners = each.value.listeners

  tags = {
    Name = each.value.name
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

output "listeners" {
  value = local.listeners
}
