locals {
  replica_numbers = [
    "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen"
  ]

  rds_configs       = var.rds_configs != null ? var.rds_configs : { current = var.rds_config }
  active_rds_config = local.rds_configs[var.active_rds_config_name]

  rds_replica_instances = {
    for config_name, config in local.rds_configs : config_name => {
      for index, replica_number in local.replica_numbers :
      replica_number => {} if index < config.replicas
    }
  }
  rds_final_snapshot_identifiers = {
    for config_name, config in local.rds_configs : config_name => config.skip_final_snapshot ? null : coalesce(
      config.final_snapshot_identifier,
      format("final-%s-%s", config.name, random_id.rds_final_snapshot_identifier[config_name].hex)
    )
  }
  rds_ecs_security_group_count = var.fleet_config.networking.security_groups == null ? 1 : length(var.fleet_config.networking.security_groups)
  rds_security_group_rules = {
    for config_name, config in local.rds_configs : config_name => merge(
      {
        for idx, sg_id in config.allowed_security_groups :
        "allowed_security_group_${idx + local.rds_ecs_security_group_count}" => {
          type                     = "ingress"
          source_security_group_id = sg_id
          description              = "Ingress from allowed security group ${sg_id}"
        }
      },
      length(config.allowed_cidr_blocks) > 0 ? {
        allowed_cidr_blocks = {
          type        = "ingress"
          cidr_blocks = config.allowed_cidr_blocks
          description = "Ingress from allowed CIDR blocks"
        }
      } : {}
    )
  }
  rds_ecs_security_group_rules = merge([
    for config_name in keys(local.rds_configs) : {
      for idx, sg_id in module.byo-db.byo-ecs.non_circular.security_groups :
      "${config_name}_${idx}" => {
        config_name              = config_name
        source_security_group_id = sg_id
      }
    }
  ]...)

  rds_storage_create_kms_keys = toset([
    for config_name, config in local.rds_configs : config_name
    if config.storage_kms.cmk_enabled == true && config.storage_kms.kms_key_arn == null
  ])
  rds_storage_kms_key_arns = {
    for config_name, config in local.rds_configs : config_name => config.storage_kms.cmk_enabled == true ? (
      config.storage_kms.kms_key_arn != null ? config.storage_kms.kms_key_arn : aws_kms_key.rds_storage[config_name].arn
    ) : null
  }

  rds_password_secret_create_kms_keys = toset([
    for config_name, config in local.rds_configs : config_name
    if config.password_secret_kms.cmk_enabled == true && config.password_secret_kms.kms_key_arn == null
  ])
  rds_password_secret_kms_key_arns = {
    for config_name, config in local.rds_configs : config_name => config.password_secret_kms.cmk_enabled == true ? (
      config.password_secret_kms.kms_key_arn != null ? config.password_secret_kms.kms_key_arn : aws_kms_key.rds_password_secret[config_name].arn
    ) : null
  }

  rds_observability_create_kms_keys = toset([
    for config_name, config in local.rds_configs : config_name
    if config.observability.performance_insights_enabled == true && config.observability.kms.cmk_enabled == true && config.observability.kms.kms_key_arn == null
  ])
  rds_observability_kms_key_arns = {
    for config_name, config in local.rds_configs : config_name => config.observability.performance_insights_enabled == true && config.observability.kms.cmk_enabled == true ? (
      config.observability.kms.kms_key_arn != null ? config.observability.kms.kms_key_arn : aws_kms_key.rds_observability[config_name].arn
    ) : null
  }

  rds_performance_insights_enabled = {
    for config_name, config in local.rds_configs : config_name => config.observability.performance_insights_enabled
  }
  rds_performance_insights_retention_periods = {
    for config_name, config in local.rds_configs : config_name => config.observability.performance_insights_enabled == true ? (
      config.observability.database_insights_mode == "advanced" ? coalesce(config.observability.retention_period, 465) : config.observability.retention_period
    ) : null
  }

  rds_cloudwatch_log_group_create_kms_keys = toset([
    for config_name, config in local.rds_configs : config_name
    if length(config.enabled_cloudwatch_logs_exports) > 0 && config.cloudwatch_log_group.kms.cmk_enabled == true && config.cloudwatch_log_group.kms.kms_key_arn == null
  ])
  rds_cloudwatch_log_group_kms_key_arns = {
    for config_name, config in local.rds_configs : config_name => length(config.enabled_cloudwatch_logs_exports) > 0 && config.cloudwatch_log_group.kms.cmk_enabled == true ? (
      config.cloudwatch_log_group.kms.kms_key_arn != null ? config.cloudwatch_log_group.kms.kms_key_arn : aws_kms_key.rds_cloudwatch_log_group[config_name].arn
    ) : null
  }
  rds_manage_cloudwatch_log_groups = {
    for config_name, config in local.rds_configs : config_name => length(config.enabled_cloudwatch_logs_exports) > 0 && (
      config.cloudwatch_log_group.retention_in_days != null ||
      config.cloudwatch_log_group.skip_destroy == true ||
      config.cloudwatch_log_group.kms.cmk_enabled == true
    )
  }

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
        identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
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

check "fleet_config_database_overrides_rds_config" {
  assert {
    condition     = var.fleet_config.database.user == null || var.fleet_config.database.user == local.active_rds_config.master_username
    error_message = "fleet_config.database.user (${coalesce(var.fleet_config.database.user, "(null)")}) overrides the active RDS config master_username (${local.active_rds_config.master_username}). If this is intentional, ignore this warning. Otherwise, remove fleet_config.database.user so it falls back to the active RDS config."
  }
  assert {
    condition     = var.fleet_config.database.database == null || var.fleet_config.database.database == local.active_rds_config.database_name
    error_message = "fleet_config.database.database (${coalesce(var.fleet_config.database.database, "(null)")}) overrides the active RDS config database_name (${local.active_rds_config.database_name}). If this is intentional, ignore this warning. Otherwise, remove fleet_config.database.database so it falls back to the active RDS config."
  }
}

check "kms_base_policy_requires_module_managed_cmk" {
  assert {
    condition = var.kms_base_policy == null || (
      length(local.rds_storage_create_kms_keys) > 0 ||
      length(local.rds_password_secret_create_kms_keys) > 0 ||
      length(local.rds_observability_create_kms_keys) > 0 ||
      length(local.rds_cloudwatch_log_group_create_kms_keys) > 0 ||
      local.redis_at_rest_create_kms_key == true ||
      local.redis_cloudwatch_log_group_create_kms_key == true
    )
    error_message = "kms_base_policy is not used by byo-vpc unless this module is creating at least one CMK. When kms_key_arn is provided, external key policies remain caller-managed."
  }
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "rds_storage_kms" {
  for_each = local.rds_storage_create_kms_keys

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = local.rds_configs[each.key].storage_kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.rds]
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
  for_each            = local.rds_storage_create_kms_keys
  description         = "CMK for Aurora storage encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_storage_kms[each.key].json
}

resource "aws_kms_alias" "rds_storage" {
  for_each      = local.rds_storage_create_kms_keys
  target_key_id = aws_kms_key.rds_storage[each.key].id
  name          = "alias/${local.rds_configs[each.key].storage_kms.kms_alias}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "rds_password_secret_kms" {
  for_each = local.rds_password_secret_create_kms_keys

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = local.rds_configs[each.key].password_secret_kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.secretsmanager]
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.execution_role]
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
  for_each            = local.rds_password_secret_create_kms_keys
  description         = "CMK for Aurora database password secret encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_password_secret_kms[each.key].json
}

resource "aws_kms_alias" "rds_password_secret" {
  for_each      = local.rds_password_secret_create_kms_keys
  target_key_id = aws_kms_key.rds_password_secret[each.key].id
  name          = "alias/${local.rds_configs[each.key].password_secret_kms.kms_alias}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "rds_observability_kms" {
  for_each = local.rds_observability_create_kms_keys

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = local.rds_configs[each.key].observability.kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.rds]
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
  for_each            = local.rds_observability_create_kms_keys
  description         = "CMK for Aurora Performance Insights and Database Insights encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_observability_kms[each.key].json
}

resource "aws_kms_alias" "rds_observability" {
  for_each      = local.rds_observability_create_kms_keys
  target_key_id = aws_kms_key.rds_observability[each.key].id
  name          = "alias/${local.rds_configs[each.key].observability.kms.kms_alias}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "rds_cloudwatch_log_group_kms" {
  for_each = local.rds_cloudwatch_log_group_create_kms_keys

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = local.rds_configs[each.key].cloudwatch_log_group.kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.cloudwatch_logs]
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
  for_each            = local.rds_cloudwatch_log_group_create_kms_keys
  description         = "CMK for Aurora exported CloudWatch Logs encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.rds_cloudwatch_log_group_kms[each.key].json
}

resource "aws_kms_alias" "rds_cloudwatch_log_group" {
  for_each      = local.rds_cloudwatch_log_group_create_kms_keys
  target_key_id = aws_kms_key.rds_cloudwatch_log_group[each.key].id
  name          = "alias/${local.rds_configs[each.key].cloudwatch_log_group.kms.kms_alias}"
}

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "redis_at_rest_kms" {
  count = local.redis_at_rest_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = var.redis_config.at_rest_kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.elasticache]
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

# Each source uses its own dynamic "statement" block to avoid Terraform type
# conflicts when concatenating typed variable values with inline literal tuples.
data "aws_iam_policy_document" "redis_cloudwatch_log_group_kms" {
  count = local.redis_cloudwatch_log_group_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = local.kms_base_policy_statements
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

  dynamic "statement" {
    for_each = var.redis_config.cloudwatch_log_group.kms.extra_kms_policies
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

  dynamic "statement" {
    for_each = [local.kms_service_statements.cloudwatch_logs]
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
      address                     = module.rds[var.active_rds_config_name].cluster_endpoint
      rr_address                  = module.rds[var.active_rds_config_name].cluster_reader_endpoint
      database                    = coalesce(var.fleet_config.database.database, local.active_rds_config.database_name)
      user                        = coalesce(var.fleet_config.database.user, local.active_rds_config.master_username)
      password_secret_arn         = module.secrets-manager-1.secret_arns["${local.active_rds_config.name}-database-password"]
      password_secret_kms_key_arn = local.rds_password_secret_kms_key_arns[var.active_rds_config_name]
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
  for_each = local.rds_configs

  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_id" "rds_final_snapshot_identifier" {
  for_each = {
    for config_name, config in local.rds_configs : config_name => config
    if config.skip_final_snapshot == false
  }

  keepers = {
    id = each.value.name
  }

  byte_length = 4
}

module "rds" {
  for_each = local.rds_configs

  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "9.16.1"

  name           = each.value.name
  engine         = "aurora-mysql"
  engine_version = each.value.engine_version
  instance_class = each.value.instance_class

  instances = local.rds_replica_instances[each.key]

  create_db_subnet_group = true
  serverlessv2_scaling_configuration = each.value.serverless ? {
    min_capacity = each.value.serverless_min_capacity
    max_capacity = each.value.serverless_max_capacity
  } : {}

  vpc_id  = var.vpc_config.vpc_id
  subnets = each.value.subnets

  security_group_rules = local.rds_security_group_rules[each.key]

  cluster_monitoring_interval                   = each.value.monitoring_interval
  cluster_performance_insights_enabled          = local.rds_performance_insights_enabled[each.key]
  cluster_performance_insights_kms_key_id       = local.rds_observability_kms_key_arns[each.key]
  cluster_performance_insights_retention_period = local.rds_performance_insights_retention_periods[each.key]
  create_cloudwatch_log_group                   = local.rds_manage_cloudwatch_log_groups[each.key]
  cloudwatch_log_group_kms_key_id               = local.rds_manage_cloudwatch_log_groups[each.key] ? local.rds_cloudwatch_log_group_kms_key_arns[each.key] : null
  cloudwatch_log_group_retention_in_days        = local.rds_manage_cloudwatch_log_groups[each.key] ? each.value.cloudwatch_log_group.retention_in_days : null
  cloudwatch_log_group_skip_destroy             = local.rds_manage_cloudwatch_log_groups[each.key] ? each.value.cloudwatch_log_group.skip_destroy : null
  database_insights_mode                        = each.value.observability.database_insights_mode
  manage_master_user_password                   = false
  storage_encrypted                             = true
  kms_key_id                                    = local.rds_storage_kms_key_arns[each.key]
  apply_immediately                             = each.value.apply_immediately
  backtrack_window                              = each.value.backtrack_window

  db_parameter_group_name         = each.value.db_parameter_group_name == null ? aws_db_parameter_group.main[each.key].id : each.value.db_parameter_group_name
  db_cluster_parameter_group_name = each.value.db_cluster_parameter_group_name == null ? aws_rds_cluster_parameter_group.main[each.key].id : each.value.db_cluster_parameter_group_name

  enabled_cloudwatch_logs_exports = each.value.enabled_cloudwatch_logs_exports
  master_username                 = each.value.master_username
  master_password                 = random_password.rds[each.key].result
  database_name                   = each.value.database_name
  skip_final_snapshot             = each.value.skip_final_snapshot
  final_snapshot_identifier       = local.rds_final_snapshot_identifiers[each.key]
  snapshot_identifier             = each.value.snapshot_identifier
  backup_retention_period         = each.value.backup_retention_period
  restore_to_point_in_time        = each.value.restore_to_point_in_time

  preferred_maintenance_window = each.value.preferred_maintenance_window

  cluster_tags = each.value.cluster_tags
}

resource "aws_security_group_rule" "rds_ecs_ingress" {
  for_each = local.rds_ecs_security_group_rules

  type                     = "ingress"
  from_port                = module.rds[each.value.config_name].cluster_port
  to_port                  = module.rds[each.value.config_name].cluster_port
  protocol                 = "tcp"
  security_group_id        = module.rds[each.value.config_name].security_group_id
  source_security_group_id = each.value.source_security_group_id
  description              = "Ingress from allowed security group ${each.value.source_security_group_id}"
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
    for config_name, config in local.rds_configs : "${config.name}-database-password" => {
      description             = "fleet-database-password"
      kms_key_id              = local.rds_password_secret_kms_key_arns[config_name]
      recovery_window_in_days = 0
      secret_string           = module.rds[config_name].cluster_master_password
    }
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
  for_each = {
    for config_name, config in local.rds_configs : config_name => config
    if config.db_parameter_group_name == null
  }

  name        = each.value.name
  family      = "aurora-mysql8.0"
  description = "fleet"

  dynamic "parameter" {
    for_each = each.value.db_parameters
    content {
      name  = parameter.key
      value = parameter.value
    }
  }
}

resource "aws_rds_cluster_parameter_group" "main" {
  for_each = {
    for config_name, config in local.rds_configs : config_name => config
    if config.db_cluster_parameter_group_name == null
  }

  name        = each.value.name
  family      = "aurora-mysql8.0"
  description = "fleet"

  dynamic "parameter" {
    for_each = each.value.db_cluster_parameters
    content {
      name  = parameter.key
      value = parameter.value
    }
  }

}
