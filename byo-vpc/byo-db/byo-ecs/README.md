# BYO ECS Module

This module deploys Fleet into an existing ECS/Fargate environment and supports optional customer-managed KMS keys (CMKs) for:

- Fleet private key secret in Secrets Manager
- Fleet application CloudWatch Logs log group encryption
- Fleet software installers S3 bucket encryption

When no KMS inputs are provided, behavior remains unchanged from prior versions.

## KMS Behavior

- `fleet_config.private_key_secret_kms.enabled = true` enables CMK encryption for the Fleet private key secret.
- `fleet_config.awslogs.kms.enabled = true` enables CMK encryption for the Fleet application log group when `fleet_config.awslogs.create = true`.
- `fleet_config.software_installers.create_kms_key = true` enables CMK encryption for software installers S3 objects.

For each feature:

- If KMS is enabled and no key ARN is provided, this module creates a CMK and alias.
- If a key ARN is provided, this module uses that key and does not create a CMK.
- For software installers, setting `software_installers.kms_key_arn` is sufficient to use that key even if `create_kms_key = false`.

IAM permissions for using these keys are managed in-module where possible. If a task role ARN is provided and belongs to the same AWS account, KMS/S3 policy attachments and `extra_iam_policies` attachments are applied to that role.

## Example: Use Module-Managed Keys

```hcl
module "fleet_byo_ecs" {
  source = "github.com/fleetdm/fleet-terraform//byo-vpc/byo-db/byo-ecs?ref=tf-mod-byo-ecs-v1.13.1"

  ecs_cluster = "fleet"
  vpc_id      = "vpc-1234567890abcdef0"

  fleet_config = {
    database = {
      password_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fleet-db"
      user                = "fleet"
      database            = "fleet"
      address             = "fleet.cluster-xyz.us-east-1.rds.amazonaws.com"
    }
    redis = {
      address = "fleet-redis.example.cache.amazonaws.com:6379"
    }
    loadbalancer = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/fleet/abc123"
    }
    networking = {
      subnets = ["subnet-aaa", "subnet-bbb"]
      ingress_sources = {
        cidr_blocks      = []
        ipv6_cidr_blocks = []
        security_groups  = []
        prefix_list_ids  = []
      }
    }
    private_key_secret_kms = {
      enabled = true
    }
    awslogs = {
      create = true
      name   = "/aws/ecs/fleet"
      kms = {
        enabled = true
      }
    }
    software_installers = {
      create_bucket  = true
      create_kms_key = true
    }
  }
}
```

## Example: Use Existing CMKs

```hcl
fleet_config = {
  private_key_secret_kms = {
    enabled     = true
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }
  awslogs = {
    create = true
    name   = "/aws/ecs/fleet"
    kms = {
      enabled     = true
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/99999999-aaaa-bbbb-cccc-dddddddddddd"
    }
  }
  software_installers = {
    create_bucket = true
    kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }
}
```

## Migration Notes

- Existing deployments are unchanged unless new KMS options are enabled.
- Enabling KMS for application logs sets `kms_key_id` on the module-managed CloudWatch log group.
- Enabling KMS for software installers updates S3 default encryption configuration.
- If you enable software installers KMS after objects already exist in the bucket, re-encrypt existing objects by copying them onto themselves:
  `aws s3 cp s3://<software-installers-bucket-name> s3://<software-installers-bucket-name> --recursive`
- Enabling KMS for the private key secret updates the secret to use the configured CMK.
- If you enable KMS on an existing CloudWatch log group, older data remains encrypted with the previous keying context. To ensure only the new key is used, delete log streams whose last event predates the `AssociateKmsKey` event for the current `kmsKeyId`.

### CloudWatch Logs KMS Migration Script

Use the helper script at `scripts/cloudwatch_logs_kms_migration.sh`. It is generic for any log group (for example Fleet app logs and ECS cluster exec logs), uses JSON output with `jq`, auto-discovers the active `kmsKeyId` and `AssociateKmsKey` cutoff, and deletes whole old streams by default.

```bash
# Dry run: list old streams only
DELETE_OLD_STREAMS=false ./scripts/cloudwatch_logs_kms_migration.sh <log-group-name> <region>

# Delete old streams (default behavior)
./scripts/cloudwatch_logs_kms_migration.sh <log-group-name> <region>
```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.89.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.7.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_appautoscaling_policy.ecs_policy_cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.ecs_policy_memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.ecs_target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_log_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_service.fleet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.backend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_policy.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.execution_extras](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.extras](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.role_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.application_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.private_key_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.application_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.private_key_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_secretsmanager_secret.fleet_server_private_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.fleet_server_private_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [random_password.fleet_server_private_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.application_logs_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.fleet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.fleet-execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_kms_key.software_installers_provided](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ecs_cluster"></a> [ecs\_cluster](#input\_ecs\_cluster) | The name of the ECS cluster to use | `string` | n/a | yes |
| <a name="input_fleet_config"></a> [fleet\_config](#input\_fleet\_config) | The configuration object for Fleet itself. Fields that default to null will have their respective resources created if not specified. | <pre>object({<br/>    task_mem                     = optional(number, null)<br/>    task_cpu                     = optional(number, null)<br/>    mem                          = optional(number, 4096)<br/>    cpu                          = optional(number, 512)<br/>    pid_mode                     = optional(string, null)<br/>    image                        = optional(string, "fleetdm/fleet:v4.81.1")<br/>    family                       = optional(string, "fleet")<br/>    sidecars                     = optional(list(any), [])<br/>    depends_on                   = optional(list(any), [])<br/>    mount_points                 = optional(list(any), [])<br/>    volumes                      = optional(list(any), [])<br/>    extra_environment_variables  = optional(map(string), {})<br/>    extra_iam_policies           = optional(list(string), [])<br/>    extra_execution_iam_policies = optional(list(string), [])<br/>    extra_secrets                = optional(map(string), {})<br/>    security_group_name          = optional(string, "fleet")<br/>    iam_role_arn                 = optional(string, null)<br/>    repository_credentials       = optional(string, "")<br/>    private_key_secret_name      = optional(string, "fleet-server-private-key")<br/>    private_key_secret_kms = optional(object({<br/>      enabled     = optional(bool, false)<br/>      kms_key_arn = optional(string, null)<br/>      kms_alias   = optional(string, "fleet-server-private-key")<br/>      }), {<br/>      enabled     = false<br/>      kms_key_arn = null<br/>      kms_alias   = "fleet-server-private-key"<br/>    })<br/>    server_tls_enabled = optional(bool, false)<br/>    service = optional(object({<br/>      name = optional(string, "fleet")<br/>      }), {<br/>      name = "fleet"<br/>    })<br/>    database = object({<br/>      password_secret_arn = string<br/>      user                = string<br/>      database            = string<br/>      address             = string<br/>      rr_address          = optional(string, null)<br/>    })<br/>    redis = object({<br/>      address = string<br/>      use_tls = optional(bool, true)<br/>    })<br/>    awslogs = optional(object({<br/>      name      = optional(string, null)<br/>      region    = optional(string, null)<br/>      create    = optional(bool, true)<br/>      prefix    = optional(string, "fleet")<br/>      retention = optional(number, 5)<br/>      kms = optional(object({<br/>        enabled     = optional(bool, false)<br/>        kms_key_arn = optional(string, null)<br/>        kms_alias   = optional(string, "fleet-application-logs")<br/>        }), {<br/>        enabled     = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-application-logs"<br/>      })<br/>      }), {<br/>      name      = null<br/>      region    = null<br/>      create    = true<br/>      prefix    = "fleet"<br/>      retention = 5<br/>      kms = {<br/>        enabled     = false<br/>        kms_key_arn = null<br/>        kms_alias   = "fleet-application-logs"<br/>      }<br/>    })<br/>    loadbalancer = object({<br/>      arn = string<br/>    })<br/>    extra_load_balancers = optional(list(any), [])<br/>    networking = object({<br/>      subnets         = optional(list(string), null)<br/>      security_groups = optional(list(string), null)<br/>      ingress_sources = object({<br/>        cidr_blocks      = optional(list(string), [])<br/>        ipv6_cidr_blocks = optional(list(string), [])<br/>        security_groups  = optional(list(string), [])<br/>        prefix_list_ids  = optional(list(string), [])<br/>      })<br/>      assign_public_ip = optional(bool, false)<br/>    })<br/>    autoscaling = optional(object({<br/>      max_capacity                 = optional(number, 5)<br/>      min_capacity                 = optional(number, 1)<br/>      memory_tracking_target_value = optional(number, 80)<br/>      cpu_tracking_target_value    = optional(number, 80)<br/>      }), {<br/>      max_capacity                 = 5<br/>      min_capacity                 = 1<br/>      memory_tracking_target_value = 80<br/>      cpu_tracking_target_value    = 80<br/>    })<br/>    iam = optional(object({<br/>      role = optional(object({<br/>        name        = optional(string, "fleet-role")<br/>        policy_name = optional(string, "fleet-iam-policy")<br/>        }), {<br/>        name        = "fleet-role"<br/>        policy_name = "fleet-iam-policy"<br/>      })<br/>      execution = optional(object({<br/>        name        = optional(string, "fleet-execution-role")<br/>        policy_name = optional(string, "fleet-execution-role")<br/>        }), {<br/>        name        = "fleet-execution-role"<br/>        policy_name = "fleet-iam-policy-execution"<br/>      })<br/>      }), {<br/>      name = "fleetdm-execution-role"<br/>    })<br/>    software_installers = optional(object({<br/>      create_bucket                      = optional(bool, true)<br/>      bucket_name                        = optional(string, null)<br/>      bucket_prefix                      = optional(string, "fleet-software-installers-")<br/>      s3_object_prefix                   = optional(string, "")<br/>      enable_bucket_versioning           = optional(bool, false)<br/>      expire_noncurrent_versions         = optional(bool, true)<br/>      noncurrent_version_expiration_days = optional(number, 30)<br/>      create_kms_key                     = optional(bool, false)<br/>      kms_key_arn                        = optional(string, null)<br/>      kms_alias                          = optional(string, "fleet-software-installers")<br/>      tags                               = optional(map(string), {})<br/>      }), {<br/>      create_bucket                      = true<br/>      bucket_name                        = null<br/>      bucket_prefix                      = "fleet-software-installers-"<br/>      s3_object_prefix                   = ""<br/>      enable_bucket_versioning           = false<br/>      expire_noncurrent_versions         = true<br/>      noncurrent_version_expiration_days = 30<br/>      create_kms_key                     = false<br/>      kms_key_arn                        = null<br/>      kms_alias                          = "fleet-software-installers"<br/>      tags                               = {}<br/>    })<br/>  })</pre> | <pre>{<br/>  "autoscaling": {<br/>    "cpu_tracking_target_value": 80,<br/>    "max_capacity": 5,<br/>    "memory_tracking_target_value": 80,<br/>    "min_capacity": 1<br/>  },<br/>  "awslogs": {<br/>    "create": true,<br/>    "kms": {<br/>      "enabled": false,<br/>      "kms_alias": "fleet-application-logs",<br/>      "kms_key_arn": null<br/>    },<br/>    "name": null,<br/>    "prefix": "fleet",<br/>    "region": null,<br/>    "retention": 5<br/>  },<br/>  "cpu": 256,<br/>  "database": {<br/>    "address": null,<br/>    "database": null,<br/>    "password_secret_arn": null,<br/>    "rr_address": null,<br/>    "user": null<br/>  },<br/>  "depends_on": [],<br/>  "extra_environment_variables": {},<br/>  "extra_execution_iam_policies": [],<br/>  "extra_iam_policies": [],<br/>  "extra_load_balacners": [],<br/>  "extra_secrets": {},<br/>  "family": "fleet",<br/>  "iam": {<br/>    "execution": {<br/>      "name": "fleet-execution-role",<br/>      "policy_name": "fleet-iam-policy-execution"<br/>    },<br/>    "role": {<br/>      "name": "fleet-role",<br/>      "policy_name": "fleet-iam-policy"<br/>    }<br/>  },<br/>  "iam_role_arn": null,<br/>  "image": "fleetdm/fleet:v4.81.1",<br/>  "loadbalancer": {<br/>    "arn": null<br/>  },<br/>  "mem": 512,<br/>  "mount_points": [],<br/>  "networking": {<br/>    "assign_public_ip": false,<br/>    "ingress_sources": {<br/>      "cidr_blocks": [],<br/>      "ipv6_cidr_blocks": [],<br/>      "prefix_list_ids": [],<br/>      "security_groups": []<br/>    },<br/>    "security_groups": null,<br/>    "subnets": null<br/>  },<br/>  "pid_mode": null,<br/>  "private_key_secret_kms": {<br/>    "enabled": false,<br/>    "kms_alias": "fleet-server-private-key",<br/>    "kms_key_arn": null<br/>  },<br/>  "private_key_secret_name": "fleet-server-private-key",<br/>  "redis": {<br/>    "address": null,<br/>    "use_tls": true<br/>  },<br/>  "repository_credentials": "",<br/>  "security_group_name": "fleet",<br/>  "server_tls_enabled": false,<br/>  "service": {<br/>    "name": "fleet"<br/>  },<br/>  "sidecars": [],<br/>  "software_installers": {<br/>    "bucket_name": null,<br/>    "bucket_prefix": "fleet-software-installers-",<br/>    "create_bucket": true,<br/>    "create_kms_key": false,<br/>    "enable_bucket_versioning": false,<br/>    "expire_noncurrent_versions": true,<br/>    "kms_alias": "fleet-software-installers",<br/>    "kms_key_arn": null,<br/>    "noncurrent_version_expiration_days": 30,<br/>    "s3_object_prefix": "",<br/>    "tags": {}<br/>  },<br/>  "task_cpu": null,<br/>  "task_mem": null,<br/>  "volumes": []<br/>}</pre> | no |
| <a name="input_migration_config"></a> [migration\_config](#input\_migration\_config) | The configuration object for Fleet's migration task. | <pre>object({<br/>    mem = number<br/>    cpu = number<br/>  })</pre> | <pre>{<br/>  "cpu": 1024,<br/>  "mem": 2048<br/>}</pre> | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | n/a | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_appautoscaling_target"></a> [appautoscaling\_target](#output\_appautoscaling\_target) | n/a |
| <a name="output_execution_iam_role_arn"></a> [execution\_iam\_role\_arn](#output\_execution\_iam\_role\_arn) | n/a |
| <a name="output_fleet_application_logs_kms_key_arn"></a> [fleet\_application\_logs\_kms\_key\_arn](#output\_fleet\_application\_logs\_kms\_key\_arn) | n/a |
| <a name="output_fleet_config"></a> [fleet\_config](#output\_fleet\_config) | n/a |
| <a name="output_fleet_s3_software_installers_config"></a> [fleet\_s3\_software\_installers\_config](#output\_fleet\_s3\_software\_installers\_config) | n/a |
| <a name="output_fleet_server_private_key_secret_arn"></a> [fleet\_server\_private\_key\_secret\_arn](#output\_fleet\_server\_private\_key\_secret\_arn) | n/a |
| <a name="output_fleet_server_private_key_secret_kms_key_arn"></a> [fleet\_server\_private\_key\_secret\_kms\_key\_arn](#output\_fleet\_server\_private\_key\_secret\_kms\_key\_arn) | n/a |
| <a name="output_iam_role_arn"></a> [iam\_role\_arn](#output\_iam\_role\_arn) | n/a |
| <a name="output_logging_config"></a> [logging\_config](#output\_logging\_config) | n/a |
| <a name="output_non_circular"></a> [non\_circular](#output\_non\_circular) | n/a |
| <a name="output_service"></a> [service](#output\_service) | n/a |
| <a name="output_task_definition"></a> [task\_definition](#output\_task\_definition) | n/a |
