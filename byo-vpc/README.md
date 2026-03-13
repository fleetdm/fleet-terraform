This module deploys Fleet into an existing VPC while still provisioning the supporting AWS services that Fleet needs, including Aurora, ElastiCache, ECS, and the ALB.

# KMS Coverage

This module adds optional CMK support for:

* Aurora storage encryption
* Aurora database password secret encryption in Secrets Manager
* Aurora observability encryption for Performance Insights / Database Insights
* Aurora exported CloudWatch log groups
* ElastiCache at-rest encryption
* ElastiCache CloudWatch log groups for `cloudwatch-logs` delivery targets
* Nested ECS cluster, Fleet service, application logs, and Fleet secrets through child-module passthroughs

For each feature:

* `cmk_enabled = true` means "use a customer-managed KMS key here."
* Set `cmk_enabled = false` or omit it to keep using the service-managed key.
* For KMS options that existed in published releases before this change, legacy `enabled` is deprecated but still accepted. Terraform plan/apply warns when it is used, and `cmk_enabled` takes precedence if both are set.
* Set `cmk_enabled = true` without a key ARN to have the module create a CMK and alias.
* Set `kms_key_arn` to use an existing CMK.

Provided CMKs must already allow the relevant AWS service in their key policy.

# Aurora Database Insights

`rds_config.observability` manages Aurora observability behavior:

* `database_insights_mode = null` leaves Standard vs Advanced unmanaged.
* `database_insights_mode = "standard"` enforces Standard Database Insights.
* `database_insights_mode = "advanced"` requires:
  * `performance_insights_enabled = true`
  * `monitoring_interval > 0`
  * `retention_period >= 465`

AWS has announced the Performance Insights console end of life for **June 30, 2026**. Standard Database Insights is a clean forward path for existing clusters that are already using Standard outside Terraform.

# Aurora Backtrack

`rds_config.backtrack_window` is optional and passes Aurora MySQL backtracking through to the upstream `rds-aurora` module.

* Set it to a value between `0` and `259200` seconds.
* Set `0` to disable backtracking explicitly.
* Leave it `null` to keep the default upstream behavior.

# Aurora Final Snapshot Naming

`rds_config.final_snapshot_identifier` is optional.

* Set it explicitly if you want a fixed final snapshot name.
* Leave it `null` to preserve the legacy generated naming pattern: `final-<rds_config.name>-<8-digit-hex>`.

# Example

```hcl
module "fleet_byo_vpc" {
  source = "github.com/fleetdm/fleet-terraform//byo-vpc?depth=1&ref=tf-mod-byo-vpc-v1.24.0"

  vpc_config = {
    vpc_id = "vpc-1234567890abcdef0"
    networking = {
      subnets = ["subnet-aaa", "subnet-bbb"]
    }
  }

  rds_config = {
    observability = {
      database_insights_mode = "standard"
      kms = {
        cmk_enabled = true
      }
    }
    storage_kms = {
      cmk_enabled = true
    }
    password_secret_kms = {
      cmk_enabled = true
    }
  }

  redis_config = {
    at_rest_kms = {
      cmk_enabled = true
    }
  }
}
```

# Migration Notes

* Existing deployments are unchanged until you enable new KMS settings.
* Upgrading from `tf-mod-byo-vpc-v1.24.0` to any newer version may plan an in-place Aurora cluster update setting cluster-level `performance_insights_enabled = true`. Older versions already enabled Performance Insights at the instance level; newer versions also manage it at the cluster level to align with Aurora Database Insights support.
* Aurora storage and some observability changes may still be sensitive changes; review your maintenance and restore strategy before applying them in production.
* If your goal is routine key rotation, prefer AWS KMS automatic rotation on the existing CMK when possible. Switching a resource to a different CMK is a separate migration with service-specific behavior.

## KMS Migration Guidance

### Aurora storage encryption (`rds_config.storage_kms`)

Changing the Aurora storage CMK is **not** an in-place re-key.

AWS documents that you can't change the KMS key of an existing encrypted Aurora DB cluster in place. To move to a different CMK, treat the change as a backup-and-restore migration:

1. Confirm you have a recent automated backup or create a fresh manual DB cluster snapshot before making changes.
2. Keep the current CMK enabled for the entire migration. Aurora and old snapshots still need it for decryption.
3. If the source cluster is already encrypted, create a **copy** of the manual snapshot using the target CMK.
4. Restore the copied snapshot as a **new** Aurora cluster. Aurora restores snapshots into a new cluster, not into the existing one.
5. Recreate or verify the expected instances, parameter groups, subnet/security settings, and any cluster endpoints on the restored cluster.
6. Validate Fleet connectivity and application behavior against the restored cluster before cutover.
7. Cut traffic over during a maintenance window, then keep the old cluster and old CMK until you are satisfied with rollback and retention requirements.

Operationally, this means enabling a new storage CMK should be planned like a cluster replacement, not a normal in-place Terraform apply.

If you want to automate the snapshot/copy/restore cutover for a byo-vpc deployment that defines `rds_config` inline in its Terraform, use the byo-vpc helper:

```bash
./byo-vpc/scripts/rds_storage_kms_migration.sh \
  --terraform-dir . \
  --config-file main.tf \
  --storage-kms-alias fleet-rds-storage-2026
```

or:

```bash
./byo-vpc/scripts/rds_storage_kms_migration.sh \
  --terraform-dir . \
  --config-file main.tf \
  --storage-kms-key-arn arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000
```

The helper script:

1. edits the caller's inline `rds_config` object in `main.tf` by default
2. pre-creates the wrapper-managed storage CMK with a targeted Terraform apply when `--storage-kms-alias` is used
3. creates a manual Aurora cluster snapshot and an encrypted copy under the target CMK
4. removes the currently managed Aurora resources from Terraform state
5. applies Terraform to restore a new Aurora cluster from the copied snapshot
6. deletes the old Aurora cluster, secret, parameter groups, subnet group, and security group after the new cluster is managed

Important operational notes for the helper:

* The restored cluster uses a new `rds_config.name`. The helper generates one automatically unless you pass `--restored-name`.
* The helper leaves `rds_config.snapshot_identifier` pinned to the copied snapshot after the migration. Removing it later would force Terraform to replace the restored cluster.
* Run the helper during a maintenance window. It automates the infrastructure steps, but you still need to plan for application cutover timing and validation.
* Use `--dry-run` first to inspect the exact names, snapshots, and Terraform state addresses it will touch.

### Aurora database password secret encryption (`rds_config.password_secret_kms`)

Changing the Secrets Manager CMK for the Fleet database password secret is an in-place metadata update. It does **not** require an Aurora backup/restore.

Before applying:

1. Ensure the applying identity can decrypt with the old key and encrypt with the new key.
2. Keep the old key enabled until you verify the secret can be read everywhere that uses it.

After the key change:

1. Secrets Manager re-encrypts the `AWSCURRENT`, `AWSPENDING`, and `AWSPREVIOUS` versions if it can decrypt them with the previous key.
2. Older versions without those staging labels can remain encrypted under the previous key.
3. If you want the current secret value to depend only on the new CMK, create a fresh secret version or rotate the secret after the CMK change.

### Aurora observability encryption (`rds_config.observability.kms`)

Changing the CMK for Performance Insights / Database Insights is an in-place observability change. AWS documents cluster and instance modifications for Performance Insights and Database Insights as no-downtime changes, but the modification can still take time to complete.

Before applying:

1. Make sure the new CMK policy allows RDS to use the key and allows the principals that need to read observability data.
2. Keep the old CMK enabled until you confirm observability data is readable after the update.
3. If enabling Advanced Database Insights at the same time, also satisfy the module requirements for `performance_insights_enabled`, `monitoring_interval`, and retention.

This path does **not** require an Aurora snapshot/restore migration.

### Aurora exported CloudWatch log groups (`rds_config.cloudwatch_log_group.kms`)

Associating a new CMK with an existing CloudWatch log group only affects **newly ingested** log events. Historical log events remain encrypted with the previous key, so the old key must remain available until that data ages out or is removed.

* For CloudWatch log group re-keying, use the repository-root script:

```bash
DELETE_OLD_STREAMS=false ./scripts/cloudwatch_logs_kms_migration.sh <log-group-name> <region>
```

### ElastiCache at-rest encryption (`redis_config.at_rest_kms`)

Changing the ElastiCache at-rest CMK is **not** an in-place re-key.

AWS documents that ElastiCache at-rest encryption can only be set when a replication group is created. Existing replication groups do not support enabling at-rest encryption later, and encrypted caches do not support manual key rotation to a different CMK. Treat a move to a new Redis/Valkey CMK as a backup-and-restore migration to a new replication group:

1. Create a fresh manual backup of the existing replication group before making changes.
2. Keep the current CMK enabled for the entire migration and retention window. Existing encrypted backups and the source replication group still depend on it.
3. Restore the backup into a **new** replication group with at-rest encryption enabled and the target CMK selected.
4. Recreate or verify parameter groups, subnet groups, security groups, maintenance settings, log delivery settings, and any auth/token settings on the restored replication group.
5. Validate Fleet cache connectivity and application behavior against the restored replication group before cutover.
6. Cut application traffic over to the new primary endpoint during a maintenance window.
7. Keep the old replication group and old CMK until rollback is no longer needed and backup retention requirements are satisfied.

Operationally, this should be planned as a replication group replacement, not a normal in-place Terraform apply.

For the default Fleet usage in this module, Redis is used as a cache rather than a durable system of record. Replacing the replication group without backup/restore is therefore not expected to be data-loss breaking for Fleet, though you should expect cache cold-start behavior after cutover. Use backup/restore if you specifically want to preserve warm cache state during the migration.

If you do **not** need to preserve warm cache state, the simplest Terraform migration is usually:

1. Enable the new Redis CMK settings.
2. Set a temporary new `redis_config.replication_group_id`, for example by appending a suffix such as `-1`.
3. Apply Terraform to create a new encrypted replication group alongside the old one.
4. Validate Fleet against the new replication group and allow the cache to warm naturally.
5. Terraform will then destroy the old replication group as part of the same replacement once the new one is ready.

This avoids the `ReplicationGroupAlreadyExists` conflict that happens when Terraform tries to replace an ElastiCache replication group in place while reusing the same replication group ID.

### ElastiCache CloudWatch log groups (`redis_config.cloudwatch_log_group.kms`)

If Redis/Valkey log delivery targets a CloudWatch log group, changing that log group's CMK behaves the same way as any other CloudWatch Logs re-key:

* only newly ingested log events use the new key
* historical log events remain encrypted with the previous key
* the previous key must remain available until old data ages out or is removed

Use the same repository-root helper for CloudWatch Logs re-keying:

```bash
DELETE_OLD_STREAMS=false ./scripts/cloudwatch_logs_kms_migration.sh <log-group-name> <region>
```

# How to update this readme

Edit `.header.md`, run `terraform init`, then run `terraform-docs markdown --header-from .header.md . > README.md`.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.73.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.35.1 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_byo-db"></a> [byo-db](#module\_byo-db) | ./byo-db | n/a |
| <a name="module_rds"></a> [rds](#module\_rds) | terraform-aws-modules/rds-aurora/aws | 9.16.1 |
| <a name="module_redis"></a> [redis](#module\_redis) | cloudposse/elasticache-redis/aws | >= 1.9.1 |
| <a name="module_secrets-manager-1"></a> [secrets-manager-1](#module\_secrets-manager-1) | lgallard/secrets-manager/aws | 0.6.1 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_parameter_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_kms_alias.rds_cloudwatch_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.rds_observability](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.rds_password_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.rds_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.redis_at_rest](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.redis_cloudwatch_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.rds_cloudwatch_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.rds_observability](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.rds_password_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.rds_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.redis_at_rest](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.redis_cloudwatch_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_rds_cluster_parameter_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_parameter_group) | resource |
| [random_id.rds_final_snapshot_identifier](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_password.rds](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.rds_cloudwatch_log_group_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.rds_observability_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.rds_password_secret_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.rds_storage_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.redis_at_rest_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.redis_cloudwatch_log_group_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alb_config"></a> [alb\_config](#input\_alb\_config) | n/a | <pre>object({<br/>    name               = optional(string, "fleet")<br/>    subnets            = list(string)<br/>    security_groups    = optional(list(string), [])<br/>    access_logs        = optional(map(string), {})<br/>    certificate_arn    = string<br/>    allowed_cidrs      = optional(list(string), ["0.0.0.0/0"])<br/>    allowed_ipv6_cidrs = optional(list(string), ["::/0"])<br/>    egress_cidrs       = optional(list(string), ["0.0.0.0/0"])<br/>    egress_ipv6_cidrs  = optional(list(string), ["::/0"])<br/>    fleet_target_group = optional(object({<br/>      protocol          = optional(string, "HTTP")<br/>      port              = optional(number, 80)<br/>      target_type       = optional(string, "ip")<br/>      create_attachment = optional(bool, false)<br/>      health_check = optional(object({<br/>        path                = optional(string, "/healthz")<br/>        matcher             = optional(string, "200")<br/>        port                = optional(string)<br/>        timeout             = optional(number, 10)<br/>        interval            = optional(number, 15)<br/>        healthy_threshold   = optional(number, 5)<br/>        unhealthy_threshold = optional(number, 5)<br/>      }), {})<br/>    }), {})<br/>    extra_target_groups        = optional(any, [])<br/>    https_listener_rules       = optional(any, [])<br/>    https_overrides            = optional(any, {})<br/>    xff_header_processing_mode = optional(string, null)<br/>    tls_policy                 = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")<br/>    idle_timeout               = optional(number, 905)<br/>    internal                   = optional(bool, false)<br/>    enable_deletion_protection = optional(bool, false)<br/>  })</pre> | n/a | yes |
| <a name="input_ecs_cluster"></a> [ecs\_cluster](#input\_ecs\_cluster) | The config for the terraform-aws-modules/ecs/aws module. For published KMS blocks, legacy `enabled` is deprecated and still accepted; prefer `cmk_enabled`. | <pre>object({<br/>    autoscaling_capacity_providers = optional(any, {})<br/>    cluster_configuration = optional(any, {<br/>      execute_command_configuration = {<br/>        logging = "OVERRIDE"<br/>        log_configuration = {<br/>          cloud_watch_log_group_name = "/aws/ecs/aws-ec2"<br/>        }<br/>      }<br/>    })<br/>    cluster_name = optional(string, "fleet")<br/>    cloudwatch_log_group = optional(object({<br/>      create            = optional(bool, true)<br/>      retention_in_days = optional(number, 90)<br/>      kms = optional(object({<br/>        cmk_enabled = optional(bool, null)<br/>        enabled     = optional(bool, null)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-ecs-cluster-logs")<br/>        }), {<br/>        cmk_enabled = null<br/>        enabled     = null<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-ecs-cluster-logs"<br/>      })<br/>      }), {<br/>      create            = true<br/>      retention_in_days = 90<br/>      kms = {<br/>        cmk_enabled = null<br/>        enabled     = null<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-ecs-cluster-logs"<br/>      }<br/>    })<br/>    cluster_settings = optional(any, {<br/>      "name" : "containerInsights",<br/>      "value" : "enabled",<br/>    })<br/>    create                                = optional(bool, true)<br/>    default_capacity_provider_use_fargate = optional(bool, true)<br/>    fargate_capacity_providers = optional(any, {<br/>      FARGATE = {<br/>        default_capacity_provider_strategy = {<br/>          weight = 100<br/>        }<br/>      }<br/>      FARGATE_SPOT = {<br/>        default_capacity_provider_strategy = {<br/>          weight = 0<br/>        }<br/>      }<br/>    })<br/>    tags = optional(map(string))<br/>  })</pre> | <pre>{<br/>  "autoscaling_capacity_providers": {},<br/>  "cloudwatch_log_group": {<br/>    "create": true,<br/>    "kms": {<br/>      "cmk_enabled": false,<br/>      "kms_alias": "fleet-ecs-cluster-logs",<br/>      "kms_key_arn": null<br/>    },<br/>    "retention_in_days": 90<br/>  },<br/>  "cluster_configuration": {<br/>    "execute_command_configuration": {<br/>      "log_configuration": {<br/>        "cloud_watch_log_group_name": "/aws/ecs/aws-ec2"<br/>      },<br/>      "logging": "OVERRIDE"<br/>    }<br/>  },<br/>  "cluster_name": "fleet",<br/>  "cluster_settings": {<br/>    "name": "containerInsights",<br/>    "value": "enabled"<br/>  },<br/>  "create": true,<br/>  "default_capacity_provider_use_fargate": true,<br/>  "fargate_capacity_providers": {<br/>    "FARGATE": {<br/>      "default_capacity_provider_strategy": {<br/>        "weight": 100<br/>      }<br/>    },<br/>    "FARGATE_SPOT": {<br/>      "default_capacity_provider_strategy": {<br/>        "weight": 0<br/>      }<br/>    }<br/>  },<br/>  "tags": {}<br/>}</pre> | no |
| <a name="input_fleet_config"></a> [fleet\_config](#input\_fleet\_config) | The configuration object for Fleet itself. Fields that default to null will have their respective resources created if not specified. For published KMS blocks, legacy `enabled` is deprecated and still accepted; prefer `cmk_enabled`. | <pre>object({<br/>    task_mem = optional(number, null)<br/>    task_cpu = optional(number, null)<br/>    ephemeral_storage = optional(object({<br/>      size_in_gib = number<br/>    }), null)<br/>    mem                          = optional(number, 4096)<br/>    cpu                          = optional(number, 512)<br/>    pid_mode                     = optional(string, null)<br/>    image                        = optional(string, "fleetdm/fleet:v4.81.2")<br/>    family                       = optional(string, "fleet")<br/>    sidecars                     = optional(list(any), [])<br/>    depends_on                   = optional(list(any), [])<br/>    mount_points                 = optional(list(any), [])<br/>    volumes                      = optional(list(any), [])<br/>    extra_environment_variables  = optional(map(string), {})<br/>    extra_iam_policies           = optional(list(string), [])<br/>    extra_execution_iam_policies = optional(list(string), [])<br/>    extra_secrets                = optional(map(string), {})<br/>    security_group_name          = optional(string, "fleet")<br/>    iam_role_arn                 = optional(string, null)<br/>    repository_credentials       = optional(string, "")<br/>    private_key_secret_name      = optional(string, "fleet-server-private-key")<br/>    private_key_secret_kms = optional(object({<br/>      cmk_enabled = optional(bool, null)<br/>      enabled     = optional(bool, null)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-server-private-key")<br/>      }), {<br/>      cmk_enabled = null<br/>      enabled     = null<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-server-private-key"<br/>    })<br/>    fargate_ephemeral_storage_kms = optional(object({<br/>      cmk_enabled = optional(bool, null)<br/>      enabled     = optional(bool, null)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-fargate-ephemeral-storage")<br/>      }), {<br/>      cmk_enabled = null<br/>      enabled     = null<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-fargate-ephemeral-storage"<br/>    })<br/>    server_tls_enabled = optional(bool, false)<br/>    service = optional(object({<br/>      name = optional(string, "fleet")<br/>      }), {<br/>      name = "fleet"<br/>    })<br/>    database = optional(object({<br/>      password_secret_arn = string<br/>      user                = string<br/>      database            = string<br/>      address             = string<br/>      rr_address          = optional(string, null)<br/>      }), {<br/>      password_secret_arn = null<br/>      user                = null<br/>      database            = null<br/>      address             = null<br/>      rr_address          = null<br/>    })<br/>    redis = optional(object({<br/>      address = string<br/>      use_tls = optional(bool, true)<br/>      }), {<br/>      address = null<br/>      use_tls = true<br/>    })<br/>    awslogs = optional(object({<br/>      name      = optional(string, null)<br/>      region    = optional(string, null)<br/>      create    = optional(bool, true)<br/>      prefix    = optional(string, "fleet")<br/>      retention = optional(number, 5)<br/>      kms = optional(object({<br/>        cmk_enabled = optional(bool, null)<br/>        enabled     = optional(bool, null)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-application-logs")<br/>        }), {<br/>        cmk_enabled = null<br/>        enabled     = null<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-application-logs"<br/>      })<br/>      }), {<br/>      name      = null<br/>      region    = null<br/>      create    = true<br/>      prefix    = "fleet"<br/>      retention = 5<br/>      kms = {<br/>        cmk_enabled = null<br/>        enabled     = null<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-application-logs"<br/>      }<br/>    })<br/>    loadbalancer = optional(object({<br/>      arn = string<br/>      }), {<br/>      arn = null<br/>    })<br/>    extra_load_balancers = optional(list(any), [])<br/>    networking = optional(object({<br/>      subnets         = optional(list(string), null)<br/>      security_groups = optional(list(string), null)<br/>      ingress_sources = optional(object({<br/>        cidr_blocks      = optional(list(string), [])<br/>        ipv6_cidr_blocks = optional(list(string), [])<br/>        security_groups  = optional(list(string), [])<br/>        prefix_list_ids  = optional(list(string), [])<br/>        }), {<br/>        cidr_blocks      = []<br/>        ipv6_cidr_blocks = []<br/>        security_groups  = []<br/>        prefix_list_ids  = []<br/>      })<br/>      assign_public_ip = optional(bool, false)<br/>      }), {<br/>      subnets         = null<br/>      security_groups = null<br/>      ingress_sources = {<br/>        cidr_blocks      = []<br/>        ipv6_cidr_blocks = []<br/>        security_groups  = []<br/>        prefix_list_ids  = []<br/>      }<br/>      assign_public_ip = false<br/>    })<br/>    autoscaling = optional(object({<br/>      max_capacity                 = optional(number, 5)<br/>      min_capacity                 = optional(number, 1)<br/>      memory_tracking_target_value = optional(number, 80)<br/>      cpu_tracking_target_value    = optional(number, 80)<br/>      }), {<br/>      max_capacity                 = 5<br/>      min_capacity                 = 1<br/>      memory_tracking_target_value = 80<br/>      cpu_tracking_target_value    = 80<br/>    })<br/>    iam = optional(object({<br/>      role = optional(object({<br/>        name        = optional(string, "fleet-role")<br/>        policy_name = optional(string, "fleet-iam-policy")<br/>        }), {<br/>        name        = "fleet-role"<br/>        policy_name = "fleet-iam-policy"<br/>      })<br/>      execution = optional(object({<br/>        name        = optional(string, "fleet-execution-role")<br/>        policy_name = optional(string, "fleet-execution-role")<br/>        }), {<br/>        name        = "fleet-execution-role"<br/>        policy_name = "fleet-iam-policy-execution"<br/>      })<br/>      }), {<br/>      name = "fleetdm-execution-role"<br/>    })<br/>    software_installers = optional(object({<br/>      create_bucket                      = optional(bool, true)<br/>      bucket_name                        = optional(string, null)<br/>      bucket_prefix                      = optional(string, "fleet-software-installers-")<br/>      s3_object_prefix                   = optional(string, "")<br/>      enable_bucket_versioning           = optional(bool, false)<br/>      expire_noncurrent_versions         = optional(bool, true)<br/>      noncurrent_version_expiration_days = optional(number, 30)<br/>      create_kms_key                     = optional(bool, false)<br/>      kms_key_arn                        = optional(string, null)<br/>      kms_alias                          = optional(string, "fleet-software-installers")<br/>      tags                               = optional(map(string), {})<br/>      }), {<br/>      create_bucket                      = true<br/>      bucket_name                        = null<br/>      bucket_prefix                      = "fleet-software-installers-"<br/>      s3_object_prefix                   = ""<br/>      enable_bucket_versioning           = false<br/>      expire_noncurrent_versions         = true<br/>      noncurrent_version_expiration_days = 30<br/>      create_kms_key                     = false<br/>      kms_key_arn                        = null<br/>      kms_alias                          = "fleet-software-installers"<br/>      tags                               = {}<br/>    })<br/>  })</pre> | <pre>{<br/>  "autoscaling": {<br/>    "cpu_tracking_target_value": 80,<br/>    "max_capacity": 5,<br/>    "memory_tracking_target_value": 80,<br/>    "min_capacity": 1<br/>  },<br/>  "awslogs": {<br/>    "create": true,<br/>    "kms": {<br/>      "cmk_enabled": null,<br/>      "enabled": null,<br/>      "kms_alias": "fleet-application-logs",<br/>      "kms_key_arn": null<br/>    },<br/>    "name": null,<br/>    "prefix": "fleet",<br/>    "region": null,<br/>    "retention": 5<br/>  },<br/>  "cpu": 512,<br/>  "database": {<br/>    "address": null,<br/>    "database": null,<br/>    "password_secret_arn": null,<br/>    "rr_address": null,<br/>    "user": null<br/>  },<br/>  "depends_on": [],<br/>  "ephemeral_storage": null,<br/>  "extra_environment_variables": {},<br/>  "extra_execution_iam_policies": [],<br/>  "extra_iam_policies": [],<br/>  "extra_load_balancers": [],<br/>  "extra_secrets": {},<br/>  "family": "fleet",<br/>  "fargate_ephemeral_storage_kms": {<br/>    "cmk_enabled": null,<br/>    "enabled": null,<br/>    "kms_alias": "fleet-fargate-ephemeral-storage",<br/>    "kms_key_arn": null<br/>  },<br/>  "iam": {<br/>    "execution": {<br/>      "name": "fleet-execution-role",<br/>      "policy_name": "fleet-iam-policy-execution"<br/>    },<br/>    "role": {<br/>      "name": "fleet-role",<br/>      "policy_name": "fleet-iam-policy"<br/>    }<br/>  },<br/>  "iam_role_arn": null,<br/>  "image": "fleetdm/fleet:v4.81.2",<br/>  "loadbalancer": {<br/>    "arn": null<br/>  },<br/>  "mem": 4096,<br/>  "mount_points": [],<br/>  "networking": {<br/>    "assign_public_ip": false,<br/>    "ingress_sources": {<br/>      "cidr_blocks": [],<br/>      "ipv6_cidr_blocks": [],<br/>      "prefix_list_ids": [],<br/>      "security_groups": []<br/>    },<br/>    "security_groups": null,<br/>    "subnets": null<br/>  },<br/>  "pid_mode": null,<br/>  "private_key_secret_kms": {<br/>    "cmk_enabled": null,<br/>    "enabled": null,<br/>    "kms_alias": "fleet-server-private-key",<br/>    "kms_key_arn": null<br/>  },<br/>  "private_key_secret_name": "fleet-server-private-key",<br/>  "redis": {<br/>    "address": null,<br/>    "use_tls": true<br/>  },<br/>  "repository_credentials": "",<br/>  "security_group_name": "fleet",<br/>  "security_groups": null,<br/>  "server_tls_enabled": false,<br/>  "service": {<br/>    "name": "fleet"<br/>  },<br/>  "sidecars": [],<br/>  "software_installers": {<br/>    "bucket_name": null,<br/>    "bucket_prefix": "fleet-software-installers-",<br/>    "create_bucket": true,<br/>    "create_kms_key": false,<br/>    "enable_bucket_versioning": false,<br/>    "expire_noncurrent_versions": true,<br/>    "kms_alias": "fleet-software-installers",<br/>    "kms_key_arn": null,<br/>    "noncurrent_version_expiration_days": 30,<br/>    "s3_object_prefix": "",<br/>    "tags": {}<br/>  },<br/>  "task_cpu": null,<br/>  "task_mem": null,<br/>  "volumes": []<br/>}</pre> | no |
| <a name="input_migration_config"></a> [migration\_config](#input\_migration\_config) | The configuration object for Fleet's migration task. | <pre>object({<br/>    mem = number<br/>    cpu = number<br/>  })</pre> | <pre>{<br/>  "cpu": 1024,<br/>  "mem": 2048<br/>}</pre> | no |
| <a name="input_rds_config"></a> [rds\_config](#input\_rds\_config) | The config for the terraform-aws-modules/rds-aurora/aws module | <pre>object({<br/>    name                            = optional(string, "fleet")<br/>    engine_version                  = optional(string, "8.0.mysql_aurora.3.07.1")<br/>    instance_class                  = optional(string, "db.t4g.large")<br/>    subnets                         = optional(list(string), [])<br/>    allowed_security_groups         = optional(list(string), [])<br/>    allowed_cidr_blocks             = optional(list(string), [])<br/>    apply_immediately               = optional(bool, true)<br/>    monitoring_interval             = optional(number, 10)<br/>    backtrack_window                = optional(number, null)<br/>    db_parameter_group_name         = optional(string)<br/>    db_parameters                   = optional(map(string), {})<br/>    db_cluster_parameter_group_name = optional(string)<br/>    db_cluster_parameters           = optional(map(string), {})<br/>    enabled_cloudwatch_logs_exports = optional(list(string), [])<br/>    final_snapshot_identifier       = optional(string, null)<br/>    password_secret_kms = optional(object({<br/>      cmk_enabled = optional(bool, false)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-rds-password-secret")<br/>      }), {<br/>      cmk_enabled = false<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-rds-password-secret"<br/>    })<br/>    storage_kms = optional(object({<br/>      cmk_enabled = optional(bool, false)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-rds-storage")<br/>      }), {<br/>      cmk_enabled = false<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-rds-storage"<br/>    })<br/>    observability = optional(object({<br/>      performance_insights_enabled = optional(bool, true)<br/>      retention_period             = optional(number, null)<br/>      database_insights_mode       = optional(string, null)<br/>      kms = optional(object({<br/>        cmk_enabled = optional(bool, false)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-rds-performance-insights")<br/>        }), {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-rds-performance-insights"<br/>      })<br/>      }), {<br/>      performance_insights_enabled = true<br/>      retention_period             = null<br/>      database_insights_mode       = null<br/>      kms = {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-rds-performance-insights"<br/>      }<br/>    })<br/>    cloudwatch_log_group = optional(object({<br/>      retention_in_days = optional(number, null)<br/>      skip_destroy      = optional(bool, false)<br/>      kms = optional(object({<br/>        cmk_enabled = optional(bool, false)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-rds-logs")<br/>        }), {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-rds-logs"<br/>      })<br/>      }), {<br/>      retention_in_days = null<br/>      skip_destroy      = false<br/>      kms = {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-rds-logs"<br/>      }<br/>    })<br/>    master_username              = optional(string, "fleet")<br/>    snapshot_identifier          = optional(string)<br/>    cluster_tags                 = optional(map(string), {})<br/>    preferred_maintenance_window = optional(string, "thu:23:00-fri:00:00")<br/>    skip_final_snapshot          = optional(bool, true)<br/>    backup_retention_period      = optional(number, 7)<br/>    replicas                     = optional(number, 2)<br/>    serverless                   = optional(bool, false)<br/>    serverless_min_capacity      = optional(number, 2)<br/>    serverless_max_capacity      = optional(number, 10)<br/>    restore_to_point_in_time     = optional(map(string), {})<br/>  })</pre> | <pre>{<br/>  "allowed_cidr_blocks": [],<br/>  "allowed_security_groups": [],<br/>  "apply_immediately": true,<br/>  "backtrack_window": null,<br/>  "backup_retention_period": 7,<br/>  "cloudwatch_log_group": {<br/>    "kms": {<br/>      "cmk_enabled": false,<br/>      "kms_alias": "fleet-rds-logs",<br/>      "kms_key_arn": null<br/>    },<br/>    "retention_in_days": null,<br/>    "skip_destroy": false<br/>  },<br/>  "cluster_tags": {},<br/>  "db_cluster_parameter_group_name": null,<br/>  "db_cluster_parameters": {},<br/>  "db_parameter_group_name": null,<br/>  "db_parameters": {},<br/>  "enabled_cloudwatch_logs_exports": [],<br/>  "engine_version": "8.0.mysql_aurora.3.07.1",<br/>  "final_snapshot_identifier": null,<br/>  "instance_class": "db.t4g.large",<br/>  "master_username": "fleet",<br/>  "monitoring_interval": 10,<br/>  "name": "fleet",<br/>  "observability": {<br/>    "database_insights_mode": null,<br/>    "kms": {<br/>      "cmk_enabled": false,<br/>      "kms_alias": "fleet-rds-performance-insights",<br/>      "kms_key_arn": null<br/>    },<br/>    "performance_insights_enabled": true,<br/>    "retention_period": null<br/>  },<br/>  "password_secret_kms": {<br/>    "cmk_enabled": false,<br/>    "kms_alias": "fleet-rds-password-secret",<br/>    "kms_key_arn": null<br/>  },<br/>  "preferred_maintenance_window": "thu:23:00-fri:00:00",<br/>  "replicas": 2,<br/>  "restore_to_point_in_time": {},<br/>  "serverless": false,<br/>  "serverless_max_capacity": 10,<br/>  "serverless_min_capacity": 2,<br/>  "skip_final_snapshot": true,<br/>  "snapshot_identifier": null,<br/>  "storage_kms": {<br/>    "cmk_enabled": false,<br/>    "kms_alias": "fleet-rds-storage",<br/>    "kms_key_arn": null<br/>  },<br/>  "subnets": []<br/>}</pre> | no |
| <a name="input_redis_config"></a> [redis\_config](#input\_redis\_config) | n/a | <pre>object({<br/>    name                          = optional(string, "fleet")<br/>    replication_group_id          = optional(string)<br/>    elasticache_subnet_group_name = optional(string, "")<br/>    allowed_security_group_ids    = optional(list(string), [])<br/>    subnets                       = list(string)<br/>    allowed_cidrs                 = list(string)<br/>    availability_zones            = optional(list(string), [])<br/>    cluster_size                  = optional(number, 3)<br/>    instance_type                 = optional(string, "cache.m5.large")<br/>    apply_immediately             = optional(bool, true)<br/>    automatic_failover_enabled    = optional(bool, false)<br/>    engine                        = optional(string, "redis")<br/>    engine_version                = optional(string, "7.1")<br/>    family                        = optional(string, "redis7")<br/>    at_rest_encryption_enabled    = optional(bool, true)<br/>    at_rest_kms = optional(object({<br/>      cmk_enabled = optional(bool, false)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-redis-at-rest")<br/>      }), {<br/>      cmk_enabled = false<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-redis-at-rest"<br/>    })<br/>    transit_encryption_enabled = optional(bool, true)<br/>    parameter = optional(list(object({<br/>      name  = string<br/>      value = string<br/>    })), [])<br/>    cloudwatch_log_group = optional(object({<br/>      retention_in_days = optional(number, null)<br/>      skip_destroy      = optional(bool, false)<br/>      kms = optional(object({<br/>        cmk_enabled = optional(bool, false)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-redis-logs")<br/>        }), {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-redis-logs"<br/>      })<br/>      }), {<br/>      retention_in_days = null<br/>      skip_destroy      = false<br/>      kms = {<br/>        cmk_enabled = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-redis-logs"<br/>      }<br/>    })<br/>    log_delivery_configuration = optional(list(map(any)), [])<br/>    tags                       = optional(map(string), {})<br/>  })</pre> | <pre>{<br/>  "allowed_cidrs": null,<br/>  "allowed_security_group_ids": [],<br/>  "apply_immediately": true,<br/>  "at_rest_encryption_enabled": true,<br/>  "at_rest_kms": {<br/>    "cmk_enabled": false,<br/>    "kms_alias": "fleet-redis-at-rest",<br/>    "kms_key_arn": null<br/>  },<br/>  "automatic_failover_enabled": false,<br/>  "availability_zones": [],<br/>  "cloudwatch_log_group": {<br/>    "kms": {<br/>      "cmk_enabled": false,<br/>      "kms_alias": "fleet-redis-logs",<br/>      "kms_key_arn": null<br/>    },<br/>    "retention_in_days": null,<br/>    "skip_destroy": false<br/>  },<br/>  "cluster_size": 3,<br/>  "elasticache_subnet_group_name": "",<br/>  "engine": "redis",<br/>  "engine_version": "7.1",<br/>  "family": "redis7",<br/>  "instance_type": "cache.m5.large",<br/>  "log_delivery_configuration": [],<br/>  "name": "fleet",<br/>  "parameter": [],<br/>  "replication_group_id": null,<br/>  "subnets": null,<br/>  "tags": {},<br/>  "transit_encryption_enabled": true<br/>}</pre> | no |
| <a name="input_vpc_config"></a> [vpc\_config](#input\_vpc\_config) | n/a | <pre>object({<br/>    vpc_id = string<br/>    networking = object({<br/>      subnets = list(string)<br/>    })<br/>  })</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_byo-db"></a> [byo-db](#output\_byo-db) | n/a |
| <a name="output_rds"></a> [rds](#output\_rds) | n/a |
| <a name="output_redis"></a> [redis](#output\_redis) | n/a |
| <a name="output_secrets"></a> [secrets](#output\_secrets) | n/a |
