// Root-module checks for the named Redis (ElastiCache) blue-green interface:
// redis_configs and active_redis_config_name are forwarded to byo-vpc with the
// root VPC's ElastiCache networking injected into every entry. Uses mock
// providers, so no AWS credentials are needed and nothing is created. "apply"
// runs only apply against the mocks. Run from the repository root:
//   terraform init -backend=false && terraform test
//
// Mocked plans and applies prove forwarding, selection, and addressing. They
// cannot prove AWS-side behavior. byo-vpc/tests/redis_configs.tftest.hcl
// covers per-entry KMS/log resources and state migration in detail.

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
  // A fixed document keeps KMS key policies stable between runs.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  // The provider validates ARN-typed arguments during the mocked applies, so
  // resources whose ARNs feed other resources get syntactically valid ARNs.
  // ElastiCache replication groups keep random mock ARNs so the runs below
  // can tell a kept replication group from a replaced one.
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

// The root byo-vpc output includes the Aurora module outputs, whose master
// password is sensitive and is rejected as a root output during apply. Aurora
// is out of scope for these checks, so replace it with fixed outputs.
override_module {
  target = module.byo-vpc.module.rds
  outputs = {
    cluster_endpoint        = "fleet.cluster-mock.us-east-2.rds.amazonaws.com"
    cluster_reader_endpoint = "fleet.cluster-ro-mock.us-east-2.rds.amazonaws.com"
    cluster_port            = 3306
    cluster_master_password = "mock-password"
    security_group_id       = "sg-0123456789abcdef0"
  }
}

variables {
  certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "legacy_redis_config_forwards_current" {
  command = plan

  assert {
    condition     = keys(module.byo-vpc.redis_clusters) == ["current"]
    error_message = "Legacy redis_config must be forwarded as the single current entry."
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
      current = {}
      next    = {}
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
      current = {}
    }
    active_redis_config_name = "next"
  }

  expect_failures = [var.active_redis_config_name]
}

// The entries below omit all networking settings. The root supplies its
// ElastiCache subnets, subnet group, private subnet CIDRs, and availability
// zones to every entry; byo-vpc requires allowed_cidrs, so these runs could not
// plan if any entry were forwarded without injection.

run "coexist_with_current_active" {
  variables {
    redis_configs = {
      current = {}
      next = {
        name = "fleet-next"
      }
    }
  }

  assert {
    condition     = keys(module.byo-vpc.redis_clusters) == ["current", "next"]
    error_message = "Both entries must be forwarded to byo-vpc."
  }

  assert {
    condition     = module.byo-vpc.redis.arn == module.byo-vpc.redis_clusters["current"].arn
    error_message = "The selected Redis output must stay on current."
  }

  assert {
    condition     = module.byo-vpc.byo-db.byo-ecs.fleet_config.redis.address == "${module.byo-vpc.redis_clusters["current"].endpoint}:${module.byo-vpc.redis_clusters["current"].port}"
    error_message = "Fleet must keep using current while active_redis_config_name is current."
  }
}

run "switch_to_next" {
  variables {
    redis_configs = {
      current = {}
      next = {
        name = "fleet-next"
      }
    }
    active_redis_config_name = "next"
  }

  assert {
    condition     = module.byo-vpc.byo-db.byo-ecs.fleet_config.redis.address == "${module.byo-vpc.redis_clusters["next"].endpoint}:${module.byo-vpc.redis_clusters["next"].port}"
    error_message = "Fleet must use next after the root selector changes."
  }

  assert {
    condition     = module.byo-vpc.redis.arn == run.coexist_with_current_active.byo-vpc.redis_clusters["next"].arn && module.byo-vpc.redis_clusters["current"].arn == run.coexist_with_current_active.byo-vpc.redis_clusters["current"].arn
    error_message = "Switching must keep both existing replication groups."
  }
}
