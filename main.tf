terraform {
  required_version = ">= 1.3.8"
}

locals {
  vpc_flow_log_cloudwatch_log_group_cmk_enabled = var.vpc.flow_log_cloudwatch_log_group_kms.cmk_enabled
  vpc_flow_log_cloudwatch_log_group_create_kms_key = var.vpc.enable_flow_log == true && var.vpc.create_flow_log_cloudwatch_log_group == true && local.vpc_flow_log_cloudwatch_log_group_cmk_enabled == true && var.vpc.flow_log_cloudwatch_log_group_kms.kms_key_arn == null
  vpc_flow_log_cloudwatch_log_group_kms_key_arn = var.vpc.enable_flow_log == true && var.vpc.create_flow_log_cloudwatch_log_group == true && local.vpc_flow_log_cloudwatch_log_group_cmk_enabled == true ? (
    var.vpc.flow_log_cloudwatch_log_group_kms.kms_key_arn != null ? var.vpc.flow_log_cloudwatch_log_group_kms.kms_key_arn : aws_kms_key.vpc_flow_log_cloudwatch_log_group[0].arn
  ) : null
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "vpc_flow_log_cloudwatch_log_group_kms" {
  count = local.vpc_flow_log_cloudwatch_log_group_create_kms_key == true ? 1 : 0

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

resource "aws_kms_key" "vpc_flow_log_cloudwatch_log_group" {
  count               = local.vpc_flow_log_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  description         = "CMK for VPC flow log CloudWatch Logs encryption."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.vpc_flow_log_cloudwatch_log_group_kms[0].json
}

resource "aws_kms_alias" "vpc_flow_log_cloudwatch_log_group" {
  count         = local.vpc_flow_log_cloudwatch_log_group_create_kms_key == true ? 1 : 0
  target_key_id = aws_kms_key.vpc_flow_log_cloudwatch_log_group[0].id
  name          = "alias/${var.vpc.flow_log_cloudwatch_log_group_kms.kms_alias}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name = var.vpc.name
  cidr = var.vpc.cidr

  azs                                       = var.vpc.azs
  private_subnets                           = var.vpc.private_subnets
  public_subnets                            = var.vpc.public_subnets
  database_subnets                          = var.vpc.database_subnets
  elasticache_subnets                       = var.vpc.elasticache_subnets
  create_database_subnet_group              = var.vpc.create_database_subnet_group
  create_database_subnet_route_table        = var.vpc.create_database_subnet_route_table
  create_elasticache_subnet_group           = var.vpc.create_elasticache_subnet_group
  create_elasticache_subnet_route_table     = var.vpc.create_elasticache_subnet_route_table
  enable_vpn_gateway                        = var.vpc.enable_vpn_gateway
  one_nat_gateway_per_az                    = var.vpc.one_nat_gateway_per_az
  single_nat_gateway                        = var.vpc.single_nat_gateway
  enable_nat_gateway                        = var.vpc.enable_nat_gateway
  enable_flow_log                           = var.vpc.enable_flow_log
  create_flow_log_cloudwatch_log_group      = var.vpc.create_flow_log_cloudwatch_log_group
  create_flow_log_cloudwatch_iam_role       = var.vpc.create_flow_log_cloudwatch_iam_role
  flow_log_max_aggregation_interval         = var.vpc.flow_log_max_aggregation_interval
  flow_log_cloudwatch_log_group_name_prefix = var.vpc.flow_log_cloudwatch_log_group_name_prefix
  flow_log_cloudwatch_log_group_name_suffix = var.vpc.flow_log_cloudwatch_log_group_name_suffix
  flow_log_cloudwatch_log_group_kms_key_id  = local.vpc_flow_log_cloudwatch_log_group_kms_key_arn
  vpc_flow_log_tags                         = var.vpc.vpc_flow_log_tags
  enable_dns_hostnames                      = var.vpc.enable_dns_hostnames
  enable_dns_support                        = var.vpc.enable_dns_support
}

module "byo-vpc" {
  source = "./byo-vpc"
  vpc_config = {
    vpc_id = module.vpc.vpc_id
    networking = {
      subnets = module.vpc.private_subnets
    }
  }
  rds_config = merge(var.rds_config, {
    subnets = module.vpc.database_subnets
  })
  redis_config = merge(var.redis_config, {
    subnets                       = module.vpc.elasticache_subnets
    allowed_cidrs                 = module.vpc.private_subnets_cidr_blocks
    elasticache_subnet_group_name = module.vpc.elasticache_subnet_group_name
    availability_zones            = var.vpc.azs
  })
  alb_config = merge(var.alb_config, {
    subnets         = module.vpc.public_subnets
    certificate_arn = var.certificate_arn
  })
  ecs_cluster  = var.ecs_cluster
  fleet_config = var.fleet_config
}
