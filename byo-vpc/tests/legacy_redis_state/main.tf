// TEST-ONLY fixture for ../redis_configs.tftest.hcl. Never use it directly.
//
// Reproduces the Redis-related state addresses that byo-vpc created before
// redis_configs existed: the singleton module.redis, the counted wrapper KMS
// keys/aliases, and aws_cloudwatch_log_group.redis keyed by the
// log_delivery_configuration index. The test applies this fixture with mocked
// providers and then plans byo-vpc against the same state to prove that the
// moved blocks adopt these objects as the "current" entry.
//
// Inputs to module.redis, the KMS keys/aliases, and the log groups mirror the
// pre-change byo-vpc expressions so the follow-up plan has nothing to replace.

variable "vpc_config" {
  type = object({
    vpc_id = string
    networking = object({
      subnets = list(string)
    })
  })
}

variable "redis_config" {
  type = object({
    name                          = optional(string, "fleet")
    replication_group_id          = optional(string)
    elasticache_subnet_group_name = optional(string, "")
    allowed_security_group_ids    = optional(list(string), [])
    subnets                       = list(string)
    allowed_cidrs                 = list(string)
    availability_zones            = optional(list(string), [])
    cluster_size                  = optional(number, 3)
    instance_type                 = optional(string, "cache.m5.large")
    apply_immediately             = optional(bool, true)
    automatic_failover_enabled    = optional(bool, false)
    engine                        = optional(string, "redis")
    engine_version                = optional(string, "7.1")
    family                        = optional(string, "redis7")
    at_rest_encryption_enabled    = optional(bool, true)
    at_rest_kms = optional(object({
      cmk_enabled        = optional(bool, false)
      kms_key_arn        = optional(string, null)
      kms_alias          = optional(string, "fleet-redis-at-rest")
      extra_kms_policies = optional(list(any), [])
      }), {
      cmk_enabled        = false
      kms_key_arn        = null
      kms_alias          = "fleet-redis-at-rest"
      extra_kms_policies = []
    })
    transit_encryption_enabled = optional(bool, true)
    parameter = optional(list(object({
      name  = string
      value = string
    })), [])
    cloudwatch_log_group = optional(object({
      retention_in_days = optional(number, null)
      skip_destroy      = optional(bool, false)
      kms = optional(object({
        cmk_enabled        = optional(bool, false)
        kms_key_arn        = optional(string, null)
        kms_alias          = optional(string, "fleet-redis-logs")
        extra_kms_policies = optional(list(any), [])
        }), {
        cmk_enabled        = false
        kms_key_arn        = null
        kms_alias          = "fleet-redis-logs"
        extra_kms_policies = []
      })
      }), {
      retention_in_days = null
      skip_destroy      = false
      kms = {
        cmk_enabled        = false
        kms_key_arn        = null
        kms_alias          = "fleet-redis-logs"
        extra_kms_policies = []
      }
    })
    log_delivery_configuration = optional(list(map(any)), [])
    tags                       = optional(map(string), {})
  })

}

locals {
  redis_at_rest_create_kms_key = var.redis_config.at_rest_encryption_enabled == true && var.redis_config.at_rest_kms.cmk_enabled == true && var.redis_config.at_rest_kms.kms_key_arn == null
  redis_at_rest_kms_key_arn = var.redis_config.at_rest_encryption_enabled == true && var.redis_config.at_rest_kms.cmk_enabled == true ? (
    var.redis_config.at_rest_kms.kms_key_arn != null ? var.redis_config.at_rest_kms.kms_key_arn : aws_kms_key.redis_at_rest[0].arn
  ) : null

  redis_cloudwatch_log_group_destinations = {
    for idx, config in var.redis_config.log_delivery_configuration :
    tostring(idx) => config if try(lower(config.destination_type), "") == "cloudwatch-logs" && try(config.destination, null) != null
  }
  redis_cloudwatch_log_group_create_kms_key = length(local.redis_cloudwatch_log_group_destinations) > 0 && var.redis_config.cloudwatch_log_group.kms.cmk_enabled == true && var.redis_config.cloudwatch_log_group.kms.kms_key_arn == null
  redis_cloudwatch_log_group_kms_key_arn = length(local.redis_cloudwatch_log_group_destinations) > 0 && var.redis_config.cloudwatch_log_group.kms.cmk_enabled == true ? (
    var.redis_config.cloudwatch_log_group.kms.kms_key_arn != null ? var.redis_config.cloudwatch_log_group.kms.kms_key_arn : aws_kms_key.redis_cloudwatch_log_group[0].arn
  ) : null
  redis_manage_cloudwatch_log_groups = length(local.redis_cloudwatch_log_group_destinations) > 0 && (
    var.redis_config.cloudwatch_log_group.retention_in_days != null ||
    var.redis_config.cloudwatch_log_group.skip_destroy == true ||
    var.redis_config.cloudwatch_log_group.kms.cmk_enabled == true
  )
}

// Statements are irrelevant here: the test mocks aws_iam_policy_document with
// a fixed json value for both this fixture and byo-vpc.
data "aws_iam_policy_document" "redis_at_rest_kms" {
  count = local.redis_at_rest_create_kms_key == true ? 1 : 0
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

module "redis" {
  source  = "cloudposse/elasticache-redis/aws"
  version = ">= 1.9.1"

  name                          = var.redis_config.name
  replication_group_id          = var.redis_config.replication_group_id == null ? var.redis_config.name : var.redis_config.replication_group_id
  elasticache_subnet_group_name = var.redis_config.elasticache_subnet_group_name == null ? var.redis_config.name : var.redis_config.elasticache_subnet_group_name
  availability_zones            = var.redis_config.availability_zones
  vpc_id                        = var.vpc_config.vpc_id
  description                   = "Fleet cache"
  subnets                       = var.redis_config.subnets
  cluster_size                  = var.redis_config.cluster_size
  instance_type                 = var.redis_config.instance_type
  apply_immediately             = var.redis_config.apply_immediately
  automatic_failover_enabled    = var.redis_config.automatic_failover_enabled
  engine                        = var.redis_config.engine
  engine_version                = var.redis_config.engine_version
  family                        = var.redis_config.family
  at_rest_encryption_enabled    = var.redis_config.at_rest_encryption_enabled
  kms_key_id                    = local.redis_at_rest_kms_key_arn
  transit_encryption_enabled    = var.redis_config.transit_encryption_enabled
  parameter                     = var.redis_config.parameter
  log_delivery_configuration    = var.redis_config.log_delivery_configuration
  additional_security_group_rules = [{
    type        = "ingress"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = var.redis_config.allowed_cidrs
  }]
  tags = var.redis_config.tags
}

resource "aws_cloudwatch_log_group" "redis" {
  for_each = local.redis_manage_cloudwatch_log_groups ? local.redis_cloudwatch_log_group_destinations : {}

  name              = each.value.destination
  retention_in_days = var.redis_config.cloudwatch_log_group.retention_in_days
  kms_key_id        = local.redis_cloudwatch_log_group_kms_key_arn
  skip_destroy      = var.redis_config.cloudwatch_log_group.skip_destroy
  tags              = var.redis_config.tags
}

output "redis_arn" {
  value = module.redis.arn
}

output "redis_security_group_id" {
  value = module.redis.security_group_id
}

output "redis_at_rest_kms_key_arn" {
  value = aws_kms_key.redis_at_rest[0].arn
}

output "redis_at_rest_kms_alias_arn" {
  value = aws_kms_alias.redis_at_rest[0].arn
}

output "redis_cloudwatch_log_group_kms_key_arn" {
  value = aws_kms_key.redis_cloudwatch_log_group[0].arn
}

output "redis_cloudwatch_log_group_kms_alias_arn" {
  value = aws_kms_alias.redis_cloudwatch_log_group[0].arn
}

output "redis_cloudwatch_log_group_arns" {
  value = { for key, log_group in aws_cloudwatch_log_group.redis : key => log_group.arn }
}
