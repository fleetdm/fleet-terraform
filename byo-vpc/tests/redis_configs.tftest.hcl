// Checks for the named Redis (ElastiCache) blue-green interface:
// redis_configs, active_redis_config_name, and the legacy redis_config
// fallback. Uses mock providers, so no AWS credentials are needed and nothing
// is created. "apply" runs only apply against the mocks. Run from byo-vpc:
//   terraform init -backend=false && terraform test
//
// Mocked plans and applies prove addressing, selection, and state adoption.
// They cannot prove AWS-side behavior such as ElastiCache create times,
// subnet/security group acceptance, or cache contents.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
      name   = "us-east-2"
    }
  }
  // A fixed document keeps KMS key policies identical between runs so the
  // state-adoption runs below only differ by address.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  // The provider validates ARN-typed arguments during the mocked applies, so
  // resources whose ARNs feed other resources get syntactically valid ARNs.
  // ElastiCache replication groups keep random mock ARNs so the lifecycle
  // runs can tell a kept replication group from a replaced one.
  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/app/fleet/0123456789abcdef"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/fleet/0123456789abcdef"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/fleet-mock"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/fleet-mock"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:fleet-mock"
    }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-2:123456789012:cluster/fleet-mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:123456789012:log-group:fleet-mock"
    }
  }
}
mock_provider "random" {}
mock_provider "null" {}
mock_provider "time" {}

// byo-vpc is normally a child module. As a test root, its rds/rds_clusters
// outputs would expose the Aurora module's sensitive master password, which
// Terraform rejects during apply. Aurora is out of scope for these checks, so
// replace it with fixed, non-sensitive outputs.
override_module {
  target = module.rds
  outputs = {
    cluster_endpoint        = "fleet.cluster-mock.us-east-2.rds.amazonaws.com"
    cluster_reader_endpoint = "fleet.cluster-ro-mock.us-east-2.rds.amazonaws.com"
    cluster_port            = 3306
    cluster_master_password = "mock-password"
    security_group_id       = "sg-0123456789abcdef0"
  }
}

variables {
  vpc_config = {
    vpc_id = "vpc-0123456789abcdef0"
    networking = {
      subnets = ["subnet-private-a", "subnet-private-b"]
    }
  }
  alb_config = {
    subnets         = ["subnet-public-a", "subnet-public-b"]
    certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }
  rds_config = {
    subnets = ["subnet-database-a", "subnet-database-b"]
  }
  redis_config = {
    subnets       = ["subnet-cache-a", "subnet-cache-b"]
    allowed_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  }
}

run "legacy_redis_config_normalizes_to_current" {
  command = plan

  assert {
    condition     = keys(module.redis) == ["current"]
    error_message = "Legacy redis_config must normalize to a single current entry."
  }

  assert {
    condition     = local.redis_configs.current.name == "fleet" && local.redis_configs.current.subnets == tolist(["subnet-cache-a", "subnet-cache-b"])
    error_message = "The synthetic current entry must be the legacy redis_config value."
  }

  assert {
    condition     = length(aws_kms_key.redis_at_rest) == 0 && length(aws_kms_key.redis_cloudwatch_log_group) == 0 && length(aws_cloudwatch_log_group.redis) == 0
    error_message = "Legacy defaults must not create wrapper-owned Redis KMS keys or log groups."
  }
}

run "redis_configs_take_precedence_over_redis_config" {
  command = plan

  variables {
    redis_config = {
      name          = "legacy-ignored"
      subnets       = ["subnet-ignored"]
      allowed_cidrs = ["10.9.9.0/24"]
      at_rest_kms = {
        cmk_enabled = true
        kms_alias   = "legacy-ignored"
      }
    }
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a", "subnet-cache-b"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
      next = {
        name          = "fleet-next"
        subnets       = ["subnet-cache-a", "subnet-cache-b"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
    }
  }

  assert {
    condition     = keys(module.redis) == ["current", "next"]
    error_message = "A non-null redis_configs map must define the Redis instances."
  }

  assert {
    condition     = local.redis_configs.current.name == "fleet" && local.redis_configs.next.name == "fleet-next"
    error_message = "redis_configs entries must keep their own names and defaults."
  }

  assert {
    condition     = length(aws_kms_key.redis_at_rest) == 0
    error_message = "redis_config must be ignored when redis_configs is set."
  }
}

run "rejects_empty_redis_configs" {
  command = plan

  variables {
    redis_configs = {}
  }

  expect_failures = [var.redis_configs]
}

run "rejects_duplicate_redis_config_names" {
  command = plan

  variables {
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
      next = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
    }
  }

  expect_failures = [var.redis_configs]
}

run "rejects_non_current_selector_with_legacy_redis_config" {
  command = plan

  variables {
    active_redis_config_name = "next"
  }

  expect_failures = [var.active_redis_config_name]
}

run "rejects_selector_missing_from_redis_configs" {
  command = plan

  variables {
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
    }
    active_redis_config_name = "next"
  }

  expect_failures = [var.active_redis_config_name]
}

run "kms_and_log_groups_are_scoped_per_config" {
  command = plan

  variables {
    // A custom base policy is only valid when some config creates a CMK.
    // Only "next" does here, so the byo-vpc kms_base_policy check must still
    // pass. fleet_config enables nested byo-db/byo-ecs CMKs so their own
    // kms_base_policy checks are satisfied too.
    kms_base_policy = [{
      sid    = "AllowAccountAdministration"
      effect = "Allow"
      principals = {
        type        = "AWS"
        identifiers = ["arn:aws:iam::123456789012:root"]
      }
      actions   = ["kms:*"]
      resources = ["*"]
    }]
    fleet_config = {
      awslogs = {
        kms = {
          cmk_enabled = true
        }
      }
      fargate_ephemeral_storage_kms = {
        cmk_enabled = true
      }
    }
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
        log_delivery_configuration = [{
          destination      = "fleet-redis-slow-log"
          destination_type = "cloudwatch-logs"
          log_format       = "json"
          log_type         = "slow-log"
        }]
        cloudwatch_log_group = {
          retention_in_days = 30
        }
      }
      next = {
        name          = "fleet-next"
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
          kms_alias   = "fleet-redis-at-rest-next"
        }
        log_delivery_configuration = [
          {
            destination      = "fleet-next-redis-slow-log"
            destination_type = "cloudwatch-logs"
            log_format       = "json"
            log_type         = "slow-log"
          },
          {
            destination      = "fleet-next-redis-engine-log"
            destination_type = "cloudwatch-logs"
            log_format       = "json"
            log_type         = "engine-log"
          },
        ]
        cloudwatch_log_group = {
          kms = {
            cmk_enabled = true
            kms_alias   = "fleet-redis-logs-next"
          }
        }
      }
    }
  }

  assert {
    condition     = keys(aws_kms_key.redis_at_rest) == ["next"] && aws_kms_alias.redis_at_rest["next"].name == "alias/fleet-redis-at-rest-next"
    error_message = "Only the next entry should create an at-rest CMK and alias."
  }

  assert {
    condition     = keys(aws_kms_key.redis_cloudwatch_log_group) == ["next"] && aws_kms_alias.redis_cloudwatch_log_group["next"].name == "alias/fleet-redis-logs-next"
    error_message = "Only the next entry should create a CloudWatch Logs CMK and alias."
  }

  assert {
    condition     = local.redis_at_rest_kms_key_arns.current == null && local.redis_cloudwatch_log_group_kms_key_arns.current == null
    error_message = "The current entry must keep service-managed keys."
  }

  assert {
    condition     = keys(aws_cloudwatch_log_group.redis) == ["0", "next_0", "next_1"]
    error_message = "current must keep bare index keys and other entries must use <config_name>_<index> keys."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.redis["0"].name == "fleet-redis-slow-log" &&
      aws_cloudwatch_log_group.redis["0"].retention_in_days == 30 &&
      aws_cloudwatch_log_group.redis["0"].kms_key_id == null &&
      aws_cloudwatch_log_group.redis["next_0"].name == "fleet-next-redis-slow-log" &&
      aws_cloudwatch_log_group.redis["next_1"].name == "fleet-next-redis-engine-log" &&
      aws_cloudwatch_log_group.redis["next_1"].retention_in_days == null
    )
    error_message = "Each managed log group must use its own entry's destination, retention, and key."
  }
}

run "kms_base_policy_without_any_module_cmk_fails_check" {
  command = plan

  variables {
    kms_base_policy = [{
      sid    = "AllowAccountAdministration"
      effect = "Allow"
      principals = {
        type        = "AWS"
        identifiers = ["arn:aws:iam::123456789012:root"]
      }
      actions   = ["kms:*"]
      resources = ["*"]
    }]
    fleet_config = {
      awslogs = {
        kms = {
          cmk_enabled = true
        }
      }
      fargate_ephemeral_storage_kms = {
        cmk_enabled = true
      }
    }
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
      next = {
        name          = "fleet-next"
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
      }
    }
  }

  expect_failures = [check.kms_base_policy_requires_module_managed_cmk]
}

// Staged lifecycle against mocked state: legacy singleton -> current+next
// (current active) -> next active -> current removed. Mocked applies give a
// replaced object a new random ARN. The at-rest kms_key_id forces replication
// group replacement, so an unchanged replication group ARN also shows that its
// CMK was kept.

run "lifecycle_legacy_singleton" {
  variables {
    redis_config = {
      subnets       = ["subnet-cache-a"]
      allowed_cidrs = ["10.0.1.0/24"]
      at_rest_kms = {
        cmk_enabled = true
      }
    }
  }

  assert {
    condition     = module.byo-db.byo-ecs.fleet_config.redis.address == "${module.redis["current"].endpoint}:${module.redis["current"].port}"
    error_message = "Fleet must use the current Redis endpoint."
  }
}

run "lifecycle_current_and_next_coexist" {
  variables {
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
        }
      }
      next = {
        name                 = "fleet-next"
        replication_group_id = "fleet-next"
        subnets              = ["subnet-cache-a"]
        allowed_cidrs        = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
          kms_alias   = "fleet-redis-at-rest-next"
        }
      }
    }
  }

  assert {
    condition     = module.redis["current"].arn == run.lifecycle_legacy_singleton.redis.arn
    error_message = "Moving redis_config into redis_configs.current must keep the existing replication group."
  }

  assert {
    condition     = keys(output.redis_clusters) == ["current", "next"] && output.redis_clusters["current"].arn != output.redis_clusters["next"].arn
    error_message = "Both replication groups must be provisioned side by side."
  }

  assert {
    condition     = output.redis.arn == output.redis_clusters["current"].arn
    error_message = "output.redis must stay on the active current entry."
  }

  assert {
    condition     = module.byo-db.byo-ecs.fleet_config.redis.address == "${module.redis["current"].endpoint}:${module.redis["current"].port}"
    error_message = "Fleet must keep using current while active_redis_config_name is current."
  }

  assert {
    condition     = keys(aws_kms_key.redis_at_rest) == ["current", "next"] && local.redis_at_rest_kms_key_arns["next"] == aws_kms_key.redis_at_rest["next"].arn
    error_message = "next must get its own at-rest CMK."
  }
}

run "lifecycle_switch_to_next" {
  variables {
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
        }
      }
      next = {
        name                 = "fleet-next"
        replication_group_id = "fleet-next"
        subnets              = ["subnet-cache-a"]
        allowed_cidrs        = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
          kms_alias   = "fleet-redis-at-rest-next"
        }
      }
    }
    active_redis_config_name = "next"
  }

  assert {
    condition     = module.byo-db.byo-ecs.fleet_config.redis.address == "${module.redis["next"].endpoint}:${module.redis["next"].port}"
    error_message = "Fleet must use the next endpoint after the selector changes."
  }

  assert {
    condition     = output.redis.arn == run.lifecycle_current_and_next_coexist.redis_clusters["next"].arn
    error_message = "output.redis must follow the selector to the existing next replication group."
  }

  assert {
    condition     = output.redis_clusters["current"].arn == run.lifecycle_current_and_next_coexist.redis_clusters["current"].arn
    error_message = "The previous replication group must be retained for rollback."
  }
}

run "lifecycle_remove_current" {
  variables {
    redis_configs = {
      next = {
        name                 = "fleet-next"
        replication_group_id = "fleet-next"
        subnets              = ["subnet-cache-a"]
        allowed_cidrs        = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
          kms_alias   = "fleet-redis-at-rest-next"
        }
      }
    }
    active_redis_config_name = "next"
  }

  assert {
    condition     = keys(module.redis) == ["next"] && keys(aws_kms_key.redis_at_rest) == ["next"]
    error_message = "Removing current must remove only the retired entry's resources."
  }

  assert {
    condition     = output.redis.arn == run.lifecycle_switch_to_next.redis.arn
    error_message = "The active next replication group must be kept when current is removed."
  }
}

// State migration: apply the pre-redis_configs addresses, then plan byo-vpc
// against the same state. A replaced or newly created object would have an
// unknown ARN during plan, so these equality checks only pass when the moved
// blocks (and the unchanged log-group keys) adopt the legacy objects.

run "migration_legacy_state" {
  state_key = "redis_migration"

  module {
    source = "./tests/legacy_redis_state"
  }

  variables {
    redis_config = {
      subnets       = ["subnet-cache-a"]
      allowed_cidrs = ["10.0.1.0/24"]
      at_rest_kms = {
        cmk_enabled = true
      }
      log_delivery_configuration = [{
        destination      = "fleet-redis-slow-log"
        destination_type = "cloudwatch-logs"
        log_format       = "json"
        log_type         = "slow-log"
      }]
      cloudwatch_log_group = {
        kms = {
          cmk_enabled = true
        }
      }
    }
  }
}

run "migration_legacy_redis_config_adopts_current" {
  command   = plan
  state_key = "redis_migration"

  variables {
    redis_config = {
      subnets       = ["subnet-cache-a"]
      allowed_cidrs = ["10.0.1.0/24"]
      at_rest_kms = {
        cmk_enabled = true
      }
      log_delivery_configuration = [{
        destination      = "fleet-redis-slow-log"
        destination_type = "cloudwatch-logs"
        log_format       = "json"
        log_type         = "slow-log"
      }]
      cloudwatch_log_group = {
        kms = {
          cmk_enabled = true
        }
      }
    }
  }

  assert {
    condition     = module.redis["current"].arn == run.migration_legacy_state.redis_arn && module.redis["current"].security_group_id == run.migration_legacy_state.redis_security_group_id
    error_message = "module.redis must move to module.redis[\"current\"] without replacement."
  }

  assert {
    condition     = aws_kms_key.redis_at_rest["current"].arn == run.migration_legacy_state.redis_at_rest_kms_key_arn && aws_kms_alias.redis_at_rest["current"].arn == run.migration_legacy_state.redis_at_rest_kms_alias_arn
    error_message = "The at-rest CMK and alias must move from [0] to [\"current\"]."
  }

  assert {
    condition     = aws_kms_key.redis_cloudwatch_log_group["current"].arn == run.migration_legacy_state.redis_cloudwatch_log_group_kms_key_arn && aws_kms_alias.redis_cloudwatch_log_group["current"].arn == run.migration_legacy_state.redis_cloudwatch_log_group_kms_alias_arn
    error_message = "The CloudWatch Logs CMK and alias must move from [0] to [\"current\"]."
  }

  assert {
    condition     = aws_cloudwatch_log_group.redis["0"].arn == run.migration_legacy_state.redis_cloudwatch_log_group_arns["0"]
    error_message = "The existing Redis log group must keep its legacy \"0\" address."
  }
}

run "migration_redis_configs_current_adopts_current" {
  command   = plan
  state_key = "redis_migration"

  variables {
    redis_configs = {
      current = {
        subnets       = ["subnet-cache-a"]
        allowed_cidrs = ["10.0.1.0/24"]
        at_rest_kms = {
          cmk_enabled = true
        }
        log_delivery_configuration = [{
          destination      = "fleet-redis-slow-log"
          destination_type = "cloudwatch-logs"
          log_format       = "json"
          log_type         = "slow-log"
        }]
        cloudwatch_log_group = {
          kms = {
            cmk_enabled = true
          }
        }
      }
    }
  }

  assert {
    condition     = module.redis["current"].arn == run.migration_legacy_state.redis_arn
    error_message = "An equivalent redis_configs.current entry must adopt the legacy replication group."
  }

  assert {
    condition     = aws_kms_key.redis_at_rest["current"].arn == run.migration_legacy_state.redis_at_rest_kms_key_arn && aws_kms_key.redis_cloudwatch_log_group["current"].arn == run.migration_legacy_state.redis_cloudwatch_log_group_kms_key_arn
    error_message = "An equivalent redis_configs.current entry must adopt the legacy CMKs."
  }

  assert {
    condition     = aws_cloudwatch_log_group.redis["0"].arn == run.migration_legacy_state.redis_cloudwatch_log_group_arns["0"]
    error_message = "An equivalent redis_configs.current entry must keep the legacy log group address."
  }
}
