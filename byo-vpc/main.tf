locals {
  replica_numbers = [
    "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen"
  ]

  rds_replica_instances = {
    for index, replica_number in local.replica_numbers :
    replica_number => {} if index < var.rds_config.replicas
  }
  rds_final_snapshot_identifier = var.rds_config.skip_final_snapshot ? null : coalesce(
    var.rds_config.final_snapshot_identifier,
    format("final-%s-%s", var.rds_config.name, random_id.rds_final_snapshot_identifier[0].hex)
  )
  rds_security_group_rules = merge(
    {
      for idx, sg_id in concat(tolist(module.byo-db.byo-ecs.non_circular.security_groups), var.rds_config.allowed_security_groups) :
      "allowed_security_group_${idx}" => {
        type                     = "ingress"
        source_security_group_id = sg_id
        description              = "Ingress from allowed security group ${sg_id}"
      }
    },
    length(var.rds_config.allowed_cidr_blocks) > 0 ? {
      allowed_cidr_blocks = {
        type        = "ingress"
        cidr_blocks = var.rds_config.allowed_cidr_blocks
        description = "Ingress from allowed CIDR blocks"
      }
    } : {}
  )

  rds_storage_cmk_enabled    = var.rds_config.storage_kms.cmk_enabled
  rds_storage_create_kms_key = local.rds_storage_cmk_enabled == true && var.rds_config.storage_kms.kms_key_arn == null
  rds_storage_kms_key_arn = local.rds_storage_cmk_enabled == true ? (
    var.rds_config.storage_kms.kms_key_arn != null ? var.rds_config.storage_kms.kms_key_arn : aws_kms_key.rds_storage[0].arn
  ) : null

  rds_password_secret_cmk_enabled    = var.rds_config.password_secret_kms.cmk_enabled
  rds_password_secret_create_kms_key = local.rds_password_secret_cmk_enabled == true && var.rds_config.password_secret_kms.kms_key_arn == null
  rds_password_secret_kms_key_arn = local.rds_password_secret_cmk_enabled == true ? (
    var.rds_config.password_secret_kms.kms_key_arn != null ? var.rds_config.password_secret_kms.kms_key_arn : aws_kms_key.rds_password_secret[0].arn
  ) : null

  rds_observability_cmk_enabled    = var.rds_config.observability.kms.cmk_enabled
  rds_observability_create_kms_key = var.rds_config.observability.performance_insights_enabled == true && local.rds_observability_cmk_enabled == true && var.rds_config.observability.kms.kms_key_arn == null
  rds_observability_kms_key_arn = var.rds_config.observability.performance_insights_enabled == true && local.rds_observability_cmk_enabled == true ? (
    var.rds_config.observability.kms.kms_key_arn != null ? var.rds_config.observability.kms.kms_key_arn : aws_kms_key.rds_observability[0].arn
  ) : null

  rds_performance_insights_enabled = var.rds_config.observability.performance_insights_enabled
  rds_performance_insights_retention_period = local.rds_performance_insights_enabled == true ? (
    var.rds_config.observability.database_insights_mode == "advanced" ? coalesce(var.rds_config.observability.retention_period, 465) : var.rds_config.observability.retention_period
  ) : null
  rds_cluster_monitoring_interval = var.rds_config.monitoring_interval

  rds_cloudwatch_log_group_cmk_enabled    = var.rds_config.cloudwatch_log_group.kms.cmk_enabled
  rds_cloudwatch_log_group_create_kms_key = length(var.rds_config.enabled_cloudwatch_logs_exports) > 0 && local.rds_cloudwatch_log_group_cmk_enabled == true && var.rds_config.cloudwatch_log_group.kms.kms_key_arn == null
  rds_cloudwatch_log_group_kms_key_arn = length(var.rds_config.enabled_cloudwatch_logs_exports) > 0 && local.rds_cloudwatch_log_group_cmk_enabled == true ? (
    var.rds_config.cloudwatch_log_group.kms.kms_key_arn != null ? var.rds_config.cloudwatch_log_group.kms.kms_key_arn : aws_kms_key.rds_cloudwatch_log_group[0].arn
  ) : null
  rds_manage_cloudwatch_log_groups = length(var.rds_config.enabled_cloudwatch_logs_exports) > 0 && (
    var.rds_config.cloudwatch_log_group.retention_in_days != null ||
    var.rds_config.cloudwatch_log_group.skip_destroy == true ||
    local.rds_cloudwatch_log_group_cmk_enabled == true
  )

  redis_at_rest_cmk_enabled    = var.redis_config.at_rest_kms.cmk_enabled
  redis_at_rest_create_kms_key = var.redis_config.at_rest_encryption_enabled == true && local.redis_at_rest_cmk_enabled == true && var.redis_config.at_rest_kms.kms_key_arn == null
  redis_at_rest_kms_key_arn = var.redis_config.at_rest_encryption_enabled == true && local.redis_at_rest_cmk_enabled == true ? (
    var.redis_config.at_rest_kms.kms_key_arn != null ? var.redis_config.at_rest_kms.kms_key_arn : aws_kms_key.redis_at_rest[0].arn
  ) : null

  redis_cloudwatch_log_group_destinations = {
    for idx, config in var.redis_config.log_delivery_configuration :
    tostring(idx) => config if try(lower(config.destination_type), "") == "cloudwatch-logs" && try(config.destination, null) != null
  }
  redis_cloudwatch_log_group_cmk_enabled    = var.redis_config.cloudwatch_log_group.kms.cmk_enabled
  redis_cloudwatch_log_group_create_kms_key = length(local.redis_cloudwatch_log_group_destinations) > 0 && local.redis_cloudwatch_log_group_cmk_enabled == true && var.redis_config.cloudwatch_log_group.kms.kms_key_arn == null
  redis_cloudwatch_log_group_kms_key_arn = length(local.redis_cloudwatch_log_group_destinations) > 0 && local.redis_cloudwatch_log_group_cmk_enabled == true ? (
    var.redis_config.cloudwatch_log_group.kms.kms_key_arn != null ? var.redis_config.cloudwatch_log_group.kms.kms_key_arn : aws_kms_key.redis_cloudwatch_log_group[0].arn
  ) : null
  # Keep the decision to manage Redis log groups based only on input-known values
  # so it can be used safely in for_each.
  redis_manage_cloudwatch_log_groups = length(local.redis_cloudwatch_log_group_destinations) > 0 && (
    var.redis_config.cloudwatch_log_group.retention_in_days != null ||
    var.redis_config.cloudwatch_log_group.skip_destroy == true ||
    local.redis_cloudwatch_log_group_cmk_enabled == true
  )
  kms_base_policy_statements = var.kms_base_policy != null ? var.kms_base_policy : [
    {
      sid    = "EnableRootPermissions"
      effect = "Allow"
      principals = {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
      }
      actions    = ["kms:*"]
      resources  = ["*"]
      conditions = []
    }
  ]
  kms_service_statements = {
    rds = {
      sid    = "AllowRDSUseOfTheKey"
      effect = "Allow"
      principals = {
        type        = "Service"
        identifiers = ["rds.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ]
      resources  = ["*"]
      conditions = []
    }
    secretsmanager = {
      sid    = "AllowSecretsManagerUseOfTheKey"
      effect = "Allow"
      principals = {
        type        = "Service"
        identifiers = ["secretsmanager.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ]
      resources  = ["*"]
      conditions = []
    }
    cloudwatch_logs = {
      sid    = "AllowCloudWatchLogsUseOfTheKey"
      effect = "Allow"
      principals = {
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.id}.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
      ]
      resources  = ["*"]
      conditions = []
    }
    elasticache = {
      sid    = "AllowElastiCacheUseOfTheKey"
      effect = "Allow"
      principals = {
        type        = "Service"
        identifiers = ["elasticache.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ]
      resources  = ["*"]
      conditions = []
    }
    execution_role = {
      sid    = "AllowExecutionRoleDecrypt"
      effect = "Allow"
      principals = {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.fleet_config.iam.execution.name}"]
      }
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey"
      ]
      resources  = ["*"]
      conditions = []
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "rds_storage_kms" {
  count = local.rds_storage_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.rds_config.storage_kms.extra_kms_policies,
      [local.kms_service_statements.rds]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "rds_storage" {
  count               = local.rds_storage_create_kms_key == true ? 1 : 0
  description         = "CMK for Aurora storage encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_storage_kms[0].json
}

resource "aws_kms_alias" "rds_storage" {
  count         = local.rds_storage_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.rds_storage[0].id
  name          = "alias/${var.rds_config.storage_kms.kms_alias}"
}

data "aws_iam_policy_document" "rds_password_secret_kms" {
  count = local.rds_password_secret_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.rds_config.password_secret_kms.extra_kms_policies,
      [local.kms_service_statements.secretsmanager],
      [local.kms_service_statements.execution_role]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "rds_password_secret" {
  count               = local.rds_password_secret_create_kms_key == true ? 1 : 0
  description         = "CMK for Aurora database password secret encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_password_secret_kms[0].json
}

resource "aws_kms_alias" "rds_password_secret" {
  count         = local.rds_password_secret_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.rds_password_secret[0].id
  name          = "alias/${var.rds_config.password_secret_kms.kms_alias}"
}

data "aws_iam_policy_document" "rds_observability_kms" {
  count = local.rds_observability_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.rds_config.observability.kms.extra_kms_policies,
      [local.kms_service_statements.rds]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "rds_observability" {
  count               = local.rds_observability_create_kms_key == true ? 1 : 0
  description         = "CMK for Aurora Performance Insights and Database Insights encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_observability_kms[0].json
}

resource "aws_kms_alias" "rds_observability" {
  count         = local.rds_observability_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.rds_observability[0].id
  name          = "alias/${var.rds_config.observability.kms.kms_alias}"
}

data "aws_iam_policy_document" "rds_cloudwatch_log_group_kms" {
  count = local.rds_cloudwatch_log_group_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.rds_config.cloudwatch_log_group.kms.extra_kms_policies,
      [local.kms_service_statements.cloudwatch_logs]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "rds_cloudwatch_log_group" {
  count               = local.rds_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  description         = "CMK for Aurora exported CloudWatch Logs encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_cloudwatch_log_group_kms[0].json
}

resource "aws_kms_alias" "rds_cloudwatch_log_group" {
  count         = local.rds_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.rds_cloudwatch_log_group[0].id
  name          = "alias/${var.rds_config.cloudwatch_log_group.kms.kms_alias}"
}

data "aws_iam_policy_document" "redis_at_rest_kms" {
  count = local.redis_at_rest_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.redis_config.at_rest_kms.extra_kms_policies,
      [local.kms_service_statements.elasticache]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "redis_at_rest" {
  count               = local.redis_at_rest_create_kms_key == true ? 1 : 0
  description         = "CMK for ElastiCache at-rest encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.redis_at_rest_kms[0].json
}

resource "aws_kms_alias" "redis_at_rest" {
  count         = local.redis_at_rest_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.redis_at_rest[0].id
  name          = "alias/${var.redis_config.at_rest_kms.kms_alias}"
}

data "aws_iam_policy_document" "redis_cloudwatch_log_group_kms" {
  count = local.redis_cloudwatch_log_group_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = concat(
      local.kms_base_policy_statements,
      var.redis_config.cloudwatch_log_group.kms.extra_kms_policies,
      [local.kms_service_statements.cloudwatch_logs]
    )
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
      principals {
        type        = statement.value.principals.type
        identifiers = statement.value.principals.identifiers
      }
      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "redis_cloudwatch_log_group" {
  count               = local.redis_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  description         = "CMK for ElastiCache CloudWatch Logs encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.redis_cloudwatch_log_group_kms[0].json
}

resource "aws_kms_alias" "redis_cloudwatch_log_group" {
  count         = local.redis_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.redis_cloudwatch_log_group[0].id
  name          = "alias/${var.redis_config.cloudwatch_log_group.kms.kms_alias}"
}

module "byo-db" {
  source          = "./byo-db"
  vpc_id          = var.vpc_config.vpc_id
  kms_base_policy = var.kms_base_policy
  fleet_config = merge(var.fleet_config, {
    database = {
      address                     = module.rds.cluster_endpoint
      rr_address                  = module.rds.cluster_reader_endpoint
      database                    = "fleet"
      user                        = "fleet"
      password_secret_arn         = module.secrets-manager-1.secret_arns["${var.rds_config.name}-database-password"]
      password_secret_kms_key_arn = local.rds_password_secret_kms_key_arn
    }
    redis = {
      address = "${module.redis.endpoint}:${module.redis.port}"
    }
    networking = {
      subnets          = var.vpc_config.networking.subnets
      security_groups  = var.fleet_config.networking.security_groups
      ingress_sources  = var.fleet_config.networking.ingress_sources
      assign_public_ip = var.fleet_config.networking.assign_public_ip
    }
  })
  ecs_cluster      = var.ecs_cluster
  migration_config = var.migration_config
  alb_config       = var.alb_config
}

resource "random_password" "rds" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_id" "rds_final_snapshot_identifier" {
  count = var.rds_config.skip_final_snapshot ? 0 : 1

  keepers = {
    id = var.rds_config.name
  }

  byte_length = 4
}

module "rds" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "9.16.1"

  name           = var.rds_config.name
  engine         = "aurora-mysql"
  engine_version = var.rds_config.engine_version
  instance_class = var.rds_config.instance_class

  instances = local.rds_replica_instances

  create_db_subnet_group = true
  serverlessv2_scaling_configuration = var.rds_config.serverless ? {
    min_capacity = var.rds_config.serverless_min_capacity
    max_capacity = var.rds_config.serverless_max_capacity
  } : {}

  vpc_id  = var.vpc_config.vpc_id
  subnets = var.rds_config.subnets

  security_group_rules = local.rds_security_group_rules

  cluster_monitoring_interval                   = local.rds_cluster_monitoring_interval
  cluster_performance_insights_enabled          = local.rds_performance_insights_enabled
  cluster_performance_insights_kms_key_id       = local.rds_observability_kms_key_arn
  cluster_performance_insights_retention_period = local.rds_performance_insights_retention_period
  create_cloudwatch_log_group                   = local.rds_manage_cloudwatch_log_groups
  cloudwatch_log_group_kms_key_id               = local.rds_manage_cloudwatch_log_groups ? local.rds_cloudwatch_log_group_kms_key_arn : null
  cloudwatch_log_group_retention_in_days        = local.rds_manage_cloudwatch_log_groups ? var.rds_config.cloudwatch_log_group.retention_in_days : null
  cloudwatch_log_group_skip_destroy             = local.rds_manage_cloudwatch_log_groups ? var.rds_config.cloudwatch_log_group.skip_destroy : null
  database_insights_mode                        = var.rds_config.observability.database_insights_mode
  manage_master_user_password                   = false
  storage_encrypted                             = true
  kms_key_id                                    = local.rds_storage_kms_key_arn
  apply_immediately                             = var.rds_config.apply_immediately
  backtrack_window                              = var.rds_config.backtrack_window

  db_parameter_group_name         = var.rds_config.db_parameter_group_name == null ? aws_db_parameter_group.main[0].id : var.rds_config.db_parameter_group_name
  db_cluster_parameter_group_name = var.rds_config.db_cluster_parameter_group_name == null ? aws_rds_cluster_parameter_group.main[0].id : var.rds_config.db_cluster_parameter_group_name

  enabled_cloudwatch_logs_exports = var.rds_config.enabled_cloudwatch_logs_exports
  master_username                 = var.rds_config.master_username
  master_password                 = random_password.rds.result
  database_name                   = "fleet"
  skip_final_snapshot             = var.rds_config.skip_final_snapshot
  final_snapshot_identifier       = local.rds_final_snapshot_identifier
  snapshot_identifier             = var.rds_config.snapshot_identifier
  backup_retention_period         = var.rds_config.backup_retention_period
  restore_to_point_in_time        = var.rds_config.restore_to_point_in_time

  preferred_maintenance_window = var.rds_config.preferred_maintenance_window

  cluster_tags = var.rds_config.cluster_tags
}

module "redis" {
  source  = "cloudposse/elasticache-redis/aws"
  version = ">= 1.9.1"

  name                          = var.redis_config.name
  replication_group_id          = var.redis_config.replication_group_id == null ? var.redis_config.name : var.redis_config.replication_group_id
  elasticache_subnet_group_name = var.redis_config.elasticache_subnet_group_name == null ? var.redis_config.name : var.redis_config.elasticache_subnet_group_name
  availability_zones            = var.redis_config.availability_zones
  vpc_id                        = var.vpc_config.vpc_id
  description                   = "Fleet cache"
  #allowed_security_group_ids = concat(var.redis_config.allowed_security_group_ids, module.byo-db.ecs.security_group)
  subnets                    = var.redis_config.subnets
  cluster_size               = var.redis_config.cluster_size
  instance_type              = var.redis_config.instance_type
  apply_immediately          = var.redis_config.apply_immediately
  automatic_failover_enabled = var.redis_config.automatic_failover_enabled
  engine                     = var.redis_config.engine
  engine_version             = var.redis_config.engine_version
  family                     = var.redis_config.family
  at_rest_encryption_enabled = var.redis_config.at_rest_encryption_enabled
  kms_key_id                 = local.redis_at_rest_kms_key_arn
  transit_encryption_enabled = var.redis_config.transit_encryption_enabled
  parameter                  = var.redis_config.parameter
  log_delivery_configuration = var.redis_config.log_delivery_configuration
  additional_security_group_rules = [{
    type        = "ingress"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = var.redis_config.allowed_cidrs
  }]
  tags = var.redis_config.tags
}

module "secrets-manager-1" {
  source  = "lgallard/secrets-manager/aws"
  version = "0.6.1"

  secrets = {
    "${var.rds_config.name}-database-password" = {
      description             = "fleet-database-password"
      kms_key_id              = local.rds_password_secret_kms_key_arn
      recovery_window_in_days = 0
      secret_string           = module.rds.cluster_master_password
    },
  }
}

resource "aws_cloudwatch_log_group" "redis" {
  for_each = local.redis_manage_cloudwatch_log_groups ? local.redis_cloudwatch_log_group_destinations : {}

  name              = each.value.destination
  retention_in_days = var.redis_config.cloudwatch_log_group.retention_in_days
  kms_key_id        = local.redis_cloudwatch_log_group_kms_key_arn
  skip_destroy      = var.redis_config.cloudwatch_log_group.skip_destroy
  tags              = var.redis_config.tags
}

resource "aws_db_parameter_group" "main" {
  count       = var.rds_config.db_parameter_group_name == null ? 1 : 0
  name        = var.rds_config.name
  family      = "aurora-mysql8.0"
  description = "fleet"

  dynamic "parameter" {
    for_each = var.rds_config.db_parameters
    content {
      name  = parameter.key
      value = parameter.value
    }
  }
}

resource "aws_rds_cluster_parameter_group" "main" {
  count       = var.rds_config.db_cluster_parameter_group_name == null ? 1 : 0
  name        = var.rds_config.name
  family      = "aurora-mysql8.0"
  description = "fleet"

  dynamic "parameter" {
    for_each = var.rds_config.db_cluster_parameters
    content {
      name  = parameter.key
      value = parameter.value
    }
  }

}
