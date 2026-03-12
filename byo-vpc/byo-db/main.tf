locals {
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
      assign_public_ip = var.fleet_config.networking.assign_public_ip
    })
  })
  fleet_target_group_health_check = merge(
    var.alb_config.fleet_target_group.health_check,
    {
      protocol = var.alb_config.fleet_target_group.protocol
    }
  )
  fleet_target_group = [
    {
      name              = var.alb_config.name
      protocol          = var.alb_config.fleet_target_group.protocol
      port              = var.alb_config.fleet_target_group.port
      target_type       = var.alb_config.fleet_target_group.target_type
      create_attachment = var.alb_config.fleet_target_group.create_attachment
      health_check      = local.fleet_target_group_health_check
    }
  ]
  target_groups = { for idx, tg in concat(local.fleet_target_group, var.alb_config.extra_target_groups) :
    "tg-${idx}" => merge(tg, {
      create_attachment = try(tg.create_attachment, false)
    })
  }
  # Adapter for terraform-aws-modules/ecs/aws v7 input renames.
  # Keep our existing ecs_cluster interface stable by translating:
  # - *_capacity_providers => cluster_capacity_providers/capacity_providers
  # - default_capacity_provider_use_fargate => default_capacity_provider_strategy
  # - cluster_settings => cluster_setting
  cluster_capacity_providers = distinct(concat(
    [for k, v in var.ecs_cluster.fargate_capacity_providers : try(v.name, k)],
    [for k, v in var.ecs_cluster.autoscaling_capacity_providers : try(v.name, k)]
  ))
  normalized_capacity_providers = {
    for k, v in var.ecs_cluster.autoscaling_capacity_providers : k => {
      name = try(v.name, null)
      auto_scaling_group_provider = try(v.auto_scaling_group_provider, {
        auto_scaling_group_arn         = try(v.auto_scaling_group_arn, null)
        managed_scaling                = try(v.managed_scaling, null)
        managed_termination_protection = try(v.managed_termination_protection, null)
      })
      managed_instances_provider = try(v.managed_instances_provider, null)
      tags                       = try(v.tags, null)
    }
  }
  default_capacity_providers = merge(
    { for k, v in var.ecs_cluster.fargate_capacity_providers : k => v if var.ecs_cluster.default_capacity_provider_use_fargate },
    { for k, v in var.ecs_cluster.autoscaling_capacity_providers : k => v if !var.ecs_cluster.default_capacity_provider_use_fargate }
  )
  default_capacity_provider_strategy = {
    for k, v in local.default_capacity_providers : k => {
      name   = try(v.name, k)
      base   = try(v.default_capacity_provider_strategy.base, null)
      weight = try(v.default_capacity_provider_strategy.weight, null)
    }
  }
  # Accept both legacy map input and list input for cluster settings.
  normalized_cluster_settings              = var.ecs_cluster.cluster_settings == null ? [] : flatten([var.ecs_cluster.cluster_settings])
  fargate_ephemeral_storage_cmk_enabled = var.fleet_config.fargate_ephemeral_storage_kms.cmk_enabled
  fargate_ephemeral_storage_create_kms_key = local.fargate_ephemeral_storage_cmk_enabled == true && var.fleet_config.fargate_ephemeral_storage_kms.kms_key_arn == null
  fargate_ephemeral_storage_kms_key_arn = local.fargate_ephemeral_storage_cmk_enabled == true ? (
    var.fleet_config.fargate_ephemeral_storage_kms.kms_key_arn != null ? var.fleet_config.fargate_ephemeral_storage_kms.kms_key_arn : aws_kms_key.fargate_ephemeral_storage[0].arn
  ) : null
  cluster_cloudwatch_log_group_name           = coalesce(try(var.ecs_cluster.cluster_configuration.execute_command_configuration.log_configuration.cloud_watch_log_group_name, null), "/aws/ecs/${var.ecs_cluster.cluster_name}")
  cluster_cloudwatch_log_group_cmk_enabled = var.ecs_cluster.cloudwatch_log_group.kms.cmk_enabled
  cluster_cloudwatch_log_group_create_kms_key = var.ecs_cluster.cloudwatch_log_group.create == true && local.cluster_cloudwatch_log_group_cmk_enabled == true && var.ecs_cluster.cloudwatch_log_group.kms.kms_key_arn == null
  cluster_cloudwatch_log_group_kms_key_arn = var.ecs_cluster.cloudwatch_log_group.create == true && local.cluster_cloudwatch_log_group_cmk_enabled == true ? (
    var.ecs_cluster.cloudwatch_log_group.kms.kms_key_arn != null ? var.ecs_cluster.cloudwatch_log_group.kms.kms_key_arn : aws_kms_key.cluster_cloudwatch_log_group[0].arn
  ) : null
  ecs_cluster_configuration = merge(
    var.ecs_cluster.cluster_configuration,
    local.cluster_cloudwatch_log_group_kms_key_arn != null ? {
      execute_command_configuration = merge(
        try(var.ecs_cluster.cluster_configuration.execute_command_configuration, {}),
        {
          log_configuration = merge(
            try(var.ecs_cluster.cluster_configuration.execute_command_configuration.log_configuration, {}),
            {
              cloud_watch_encryption_enabled = true
            }
          )
        }
      )
    } : {},
    local.fargate_ephemeral_storage_kms_key_arn != null ? {
      managed_storage_configuration = merge(
        try(var.ecs_cluster.cluster_configuration.managed_storage_configuration, {}),
        {
          fargate_ephemeral_storage_kms_key_id = local.fargate_ephemeral_storage_kms_key_arn
        }
      )
    } : {}
  )
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

module "ecs" {
  source           = "./byo-ecs"
  ecs_cluster      = module.cluster.cluster_name
  fleet_config     = local.fleet_config
  migration_config = var.migration_config
  vpc_id           = var.vpc_id
}

module "cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "7.4.0"

  capacity_providers                     = local.normalized_capacity_providers
  cloudwatch_log_group_kms_key_id        = local.cluster_cloudwatch_log_group_kms_key_arn
  cloudwatch_log_group_name              = local.cluster_cloudwatch_log_group_name
  cloudwatch_log_group_retention_in_days = var.ecs_cluster.cloudwatch_log_group.retention_in_days
  cluster_capacity_providers             = local.cluster_capacity_providers
  cluster_configuration                  = local.ecs_cluster_configuration
  cluster_name                           = var.ecs_cluster.cluster_name
  cluster_setting                        = local.normalized_cluster_settings
  create_cloudwatch_log_group            = var.ecs_cluster.cloudwatch_log_group.create
  create                                 = var.ecs_cluster.create
  default_capacity_provider_strategy     = local.default_capacity_provider_strategy
  tags                                   = var.ecs_cluster.tags
}

data "aws_iam_policy_document" "fargate_ephemeral_storage_kms" {
  count = local.fargate_ephemeral_storage_create_kms_key == true ? 1 : 0

  statement {
    sid    = "EnableRootPermissions"
    effect = "Allow"
    actions = [
      "kms:*"
    ]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }

  statement {
    sid    = "AllowGenerateDataKeyWithoutPlaintextForFargateTasks"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKeyWithoutPlaintext"
    ]
    principals {
      type        = "Service"
      identifiers = ["fargate.amazonaws.com"]
    }
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ecs:clusterAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ecs:clusterName"
      values   = [var.ecs_cluster.cluster_name]
    }
  }

  statement {
    sid    = "AllowCreateGrantForFargateTasks"
    effect = "Allow"
    actions = [
      "kms:CreateGrant"
    ]
    principals {
      type        = "Service"
      identifiers = ["fargate.amazonaws.com"]
    }
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ecs:clusterAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ecs:clusterName"
      values   = [var.ecs_cluster.cluster_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "kms:GrantOperations"
      values   = ["Decrypt"]
    }
  }
}

resource "aws_kms_key" "fargate_ephemeral_storage" {
  count               = local.fargate_ephemeral_storage_create_kms_key == true ? 1 : 0
  description         = "CMK for ECS Fargate ephemeral storage encryption for the Fleet ECS cluster."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.fargate_ephemeral_storage_kms[0].json
}

resource "aws_kms_alias" "fargate_ephemeral_storage" {
  count         = local.fargate_ephemeral_storage_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.fargate_ephemeral_storage[0].id
  name          = "alias/${var.fleet_config.fargate_ephemeral_storage_kms.kms_alias}"
}

data "aws_iam_policy_document" "cluster_cloudwatch_log_group_kms" {
  count = local.cluster_cloudwatch_log_group_create_kms_key == true ? 1 : 0

  statement {
    sid    = "EnableRootPermissions"
    effect = "Allow"
    actions = [
      "kms:*"
    ]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsUseOfTheKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.id}.amazonaws.com"]
    }
    resources = ["*"]
  }
}

resource "aws_kms_key" "cluster_cloudwatch_log_group" {
  count               = local.cluster_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  description         = "CMK for ECS cluster execute-command CloudWatch Logs log group encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.cluster_cloudwatch_log_group_kms[0].json
}

resource "aws_kms_alias" "cluster_cloudwatch_log_group" {
  count         = local.cluster_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.cluster_cloudwatch_log_group[0].id
  name          = "alias/${var.ecs_cluster.cloudwatch_log_group.kms.kms_alias}"
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.17.0"

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
      forward = {
        target_group_key = "tg-0"
      }
      rules = { for idx, rule in var.alb_config.https_listener_rules :
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
      }
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
