data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  secrets_cmk_enabled         = var.secrets_kms.cmk_enabled
  secrets_provided_kms_key_id = var.secrets_kms.kms_key_arn
  secrets_create_kms_key      = local.secrets_cmk_enabled == true && local.secrets_provided_kms_key_id == null
  secrets_kms_key_arn = local.secrets_cmk_enabled == true ? (
    local.secrets_provided_kms_key_id != null ? data.aws_kms_key.provided[0].arn : aws_kms_key.secrets[0].arn
  ) : null
  fleet_execution_role_name = (
    var.secrets_kms.fleet_execution_role_name != null &&
    trimspace(var.secrets_kms.fleet_execution_role_name) != ""
  ) ? trimspace(var.secrets_kms.fleet_execution_role_name) : null
  secrets_kms_base_policy_statements = var.secrets_kms.kms_base_policy != null ? var.secrets_kms.kms_base_policy : [
    {
      sid       = "EnableRootPermissions"
      effect    = "Allow"
      actions   = ["kms:*"]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
      }
      conditions = []
    }
  ]
  secrets_kms_service_statements = [
    {
      sid       = "AllowSecretsManagerUseOfTheKey"
      effect    = "Allow"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
      resources = ["*"]
      principals = {
        type        = "Service"
        identifiers = ["secretsmanager.amazonaws.com"]
      }
      conditions = []
    }
  ]
  secrets_kms_execution_role_statements = local.fleet_execution_role_name != null ? [
    {
      sid       = "AllowFleetExecutionRoleDecrypt"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = ["*"]
      principals = {
        type        = "AWS"
        identifiers = [data.aws_iam_role.fleet_execution[0].arn]
      }
      conditions = []
    }
  ] : []
}

check "kms_base_policy_requires_module_managed_cmk" {
  assert {
    condition = var.secrets_kms.kms_base_policy == null || (
      local.secrets_create_kms_key == true
    )
    error_message = "secrets_kms.kms_base_policy is not used by mdm unless this module is creating the secrets CMK. When kms_key_arn is provided, external key policies remain caller-managed."
  }
}

data "aws_kms_key" "provided" {
  count  = local.secrets_provided_kms_key_id != null ? 1 : 0
  key_id = local.secrets_provided_kms_key_id
}

data "aws_iam_role" "fleet_execution" {
  count = local.secrets_create_kms_key == true && local.fleet_execution_role_name != null ? 1 : 0
  name  = local.fleet_execution_role_name
}

data "aws_iam_policy_document" "secrets_kms" {
  count = local.secrets_create_kms_key == true ? 1 : 0

  dynamic "statement" {
    for_each = local.secrets_kms_base_policy_statements
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
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
    for_each = var.secrets_kms.extra_kms_policies
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
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
    for_each = local.secrets_kms_service_statements
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
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
    for_each = local.secrets_kms_execution_role_statements
    content {
      sid       = try(statement.value.sid, "")
      effect    = try(statement.value.effect, null)
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
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

resource "aws_kms_key" "secrets" {
  count               = local.secrets_create_kms_key == true ? 1 : 0
  description         = "CMK for Fleet MDM Secrets Manager secret encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.secrets_kms[0].json
}

resource "aws_kms_alias" "secrets" {
  count         = local.secrets_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.secrets[0].id
  name          = "alias/${var.secrets_kms.kms_alias}"
}

resource "aws_secretsmanager_secret" "apn" {
  count      = var.apn_secret_name == null ? 0 : 1
  name       = var.apn_secret_name
  kms_key_id = local.secrets_kms_key_arn

  recovery_window_in_days = "0"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_secretsmanager_secret" "scep" {
  name       = var.scep_secret_name
  kms_key_id = local.secrets_kms_key_arn

  recovery_window_in_days = "0"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_secretsmanager_secret" "abm" {
  count      = var.abm_secret_name == null ? 0 : 1
  name       = var.abm_secret_name
  kms_key_id = local.secrets_kms_key_arn

  recovery_window_in_days = "0"
  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "main" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(var.enable_apple_mdm == false ? [] : [aws_secretsmanager_secret.apn[0].arn],
      [aws_secretsmanager_secret.scep.arn],
    var.abm_secret_name == null ? [] : [aws_secretsmanager_secret.abm[0].arn])
  }

  dynamic "statement" {
    for_each = local.secrets_kms_key_arn != null ? [local.secrets_kms_key_arn] : []
    content {
      sid       = "UseMDMSecretsKMSKey"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "main" {
  policy = data.aws_iam_policy_document.main.json
}
