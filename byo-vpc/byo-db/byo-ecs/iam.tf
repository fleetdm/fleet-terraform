locals {
  # Resolve a role name for policy attachments in both modes:
  # - module-managed role (iam_role_arn == null), or
  # - caller-provided same-account role ARN (attachment needs a role name, not ARN).
  # Cross-account ARNs intentionally return null so we do not attempt out-of-account mutation.
  task_role_name = var.fleet_config.iam_role_arn == null ? var.fleet_config.iam.role.name : (
    can(split(":", var.fleet_config.iam_role_arn)[4]) && split(":", var.fleet_config.iam_role_arn)[4] == data.aws_caller_identity.current.account_id && can(split("role/", var.fleet_config.iam_role_arn)[1]) ? split("role/", var.fleet_config.iam_role_arn)[1] : null
  )
  software_installers_kms_policy = local.software_installers_kms_key_arn != null && local.software_installers_create_kms_key == false ? [{
    sid = "AllowSoftwareInstallersKMSAccess"
    actions = [
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Encrypt",
      "kms:DescribeKey",
      "kms:Decrypt"
    ]
    resources = [local.software_installers_kms_key_arn]
    effect    = "Allow"
  }] : []
  private_key_secret_kms_policy = local.private_key_secret_kms_key_arn != null && local.private_key_secret_create_kms_key == false ? [{
    sid = "AllowFleetPrivateKeySecretKMSAccess"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = [local.private_key_secret_kms_key_arn]
    effect    = "Allow"
  }] : []
  database_password_secret_kms_policy = var.fleet_config.database.password_secret_kms_key_arn != null ? [{
    sid = "AllowFleetDatabasePasswordSecretKMSAccess"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = [var.fleet_config.database.password_secret_kms_key_arn]
    effect    = "Allow"
  }] : []
  private_key_secret_access_policy = [{
    sid       = "AllowFleetPrivateKeySecretAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.private_key_secret_arn]
    effect    = "Allow"
  }]
  execution_secret_policy = concat([{
    sid       = "AllowFleetDatabasePasswordSecretAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.fleet_config.database.password_secret_arn]
    effect    = "Allow"
  }], var.fleet_config.private_key_delivery_method == "ecs" ? local.private_key_secret_access_policy : [])
  fleet_secret_policy = var.fleet_config.private_key_delivery_method == "iam" ? local.private_key_secret_access_policy : []
  execution_kms_policy = concat(
    var.fleet_config.private_key_delivery_method == "ecs" ? local.private_key_secret_kms_policy : [],
    local.database_password_secret_kms_policy
  )
  fleet_kms_policy = var.fleet_config.private_key_delivery_method == "iam" ? local.private_key_secret_kms_policy : []
}

data "aws_iam_policy_document" "software_installers" {
  count = var.fleet_config.software_installers.create_bucket == true && local.task_role_name != null ? 1 : 0
  statement {
    actions = [
      "s3:GetObject*",
      "s3:PutObject*",
      "s3:ListBucket*",
      "s3:ListMultipartUploadParts*",
      "s3:DeleteObject",
      "s3:CreateMultipartUpload",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.software_installers[0].arn, "${aws_s3_bucket.software_installers[0].arn}/*"]
  }

  dynamic "statement" {
    for_each = local.software_installers_kms_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }
}

resource "aws_iam_policy" "software_installers" {
  count  = var.fleet_config.software_installers.create_bucket == true && local.task_role_name != null ? 1 : 0
  policy = data.aws_iam_policy_document.software_installers[count.index].json
}

resource "aws_iam_role_policy_attachment" "software_installers" {
  count      = var.fleet_config.software_installers.create_bucket == true && local.task_role_name != null ? 1 : 0
  policy_arn = aws_iam_policy.software_installers[0].arn
  role       = local.task_role_name
}

data "aws_iam_policy_document" "fleet" {
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.fleet_secret_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }

  dynamic "statement" {
    for_each = local.fleet_kms_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }

}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["ecs.amazonaws.com", "ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "fleet-execution" {
  dynamic "statement" {
    for_each = local.execution_secret_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }

  dynamic "statement" {
    for_each = local.execution_kms_policy
    content {
      sid       = try(statement.value.sid, "")
      actions   = try(statement.value.actions, [])
      resources = try(statement.value.resources, [])
      effect    = try(statement.value.effect, null)
    }
  }
}

resource "aws_iam_role" "main" {
  count              = var.fleet_config.iam_role_arn == null ? 1 : 0
  name               = var.fleet_config.iam.role.name
  description        = "IAM role that Fleet application assumes when running in ECS"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_policy" "main" {
  count       = var.fleet_config.iam_role_arn == null ? 1 : 0
  name        = var.fleet_config.iam.role.policy_name
  description = "IAM policy that Fleet application uses to define access to AWS resources"
  policy      = data.aws_iam_policy_document.fleet.json
}

resource "aws_iam_role_policy_attachment" "main" {
  count      = var.fleet_config.iam_role_arn == null ? 1 : 0
  policy_arn = aws_iam_policy.main[0].arn
  role       = aws_iam_role.main[0].name
}

resource "aws_iam_role_policy_attachment" "extras" {
  count      = local.task_role_name == null ? 0 : length(var.fleet_config.extra_iam_policies)
  policy_arn = var.fleet_config.extra_iam_policies[count.index]
  role       = local.task_role_name
}

resource "aws_iam_role_policy_attachment" "execution_extras" {
  count      = length(var.fleet_config.extra_execution_iam_policies)
  policy_arn = var.fleet_config.extra_execution_iam_policies[count.index]
  role       = aws_iam_role.execution.name
}

resource "aws_iam_policy" "execution" {
  name        = var.fleet_config.iam.execution.policy_name
  description = "IAM policy that Fleet application uses to define access to AWS resources"
  policy      = data.aws_iam_policy_document.fleet-execution.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  policy_arn = aws_iam_policy.execution.arn
  role       = aws_iam_role.execution.name
}

resource "aws_iam_role" "execution" {
  name               = var.fleet_config.iam.execution.name
  description        = "The execution role for Fleet in ECS"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "role_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.execution.name
}
