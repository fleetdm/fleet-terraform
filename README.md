This module provides a basic [Fleet](https://fleetdm.com) with Terraform. This assumes that you bring nothing to the installation.
If you want to bring your own VPC/database/cache nodes/ECS cluster, then use one of the submodules provided.

To quickly list all available module versions you can run:
```shell
git tag |grep '^tf'
```

The following is the module layout, so you can navigate to the module that you want:

* Root module (use this to get a Fleet instance ASAP with minimal setup)
    * BYO-VPC (use this if you want to install Fleet inside an existing VPC)
        * BYO-database (use this if you want to use an existing database and cache node)
            * BYO-ECS (use this if you want to bring your own everything but Fleet ECS services)

# Migrating from existing Dogfood code
The below code describes how to migrate from existing Dogfood code

```hcl
moved {
  from = module.vpc
  to   = module.main.module.vpc
}

moved {
  from = module.aurora_mysql
  to = module.main.module.byo-vpc.module.rds
}

moved {
  from = aws_elasticache_replication_group.default
  to = module.main.module.byo-vpc.module.redis.aws_elasticache_replication_group.default
}
```

This focuses on the resources that are "heavy" or store data. Note that the ALB cannot be moved like this because Dogfood uses the `aws_alb` resource and the module uses the `aws_lb` resource. The resources are aliases of eachother, but Terraform can't recognize that.

# How to improve this module
If this module somehow doesn't fit your needs, feel free to contact us by
opening a ticket, or contacting your contact at Fleet. Our goal is to make this module
fit all needs within AWS, so we will try to find a solution so that this module fits your needs.

If you want to make the changes yourself, simply make a PR into main with your additions.
We would ask that you make sure that variables are defined as null if there is
no default that makes sense and that variable changes are reflected all the way up the stack.

# How to update this readme
Edit .header.md and run `terraform-docs markdown . > README.md`

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.8 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_byo-vpc"></a> [byo-vpc](#module\_byo-vpc) | ./byo-vpc | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 5.1.2 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alb_config"></a> [alb\_config](#input\_alb\_config) | n/a | <pre>object({<br/>    name                 = optional(string, "fleet")<br/>    security_groups      = optional(list(string), [])<br/>    access_logs          = optional(map(string), {})<br/>    allowed_cidrs        = optional(list(string), ["0.0.0.0/0"])<br/>    allowed_ipv6_cidrs   = optional(list(string), ["::/0"])<br/>    egress_cidrs         = optional(list(string), ["0.0.0.0/0"])<br/>    egress_ipv6_cidrs    = optional(list(string), ["::/0"])<br/>    extra_target_groups  = optional(any, [])<br/>    https_listener_rules = optional(any, [])<br/>    tls_policy           = optional(string, "ELBSecurityPolicy-TLS-1-2-2017-01")<br/>    idle_timeout         = optional(number, 905)<br/>  })</pre> | `{}` | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | n/a | `string` | n/a | yes |
| <a name="input_ecs_cluster"></a> [ecs\_cluster](#input\_ecs\_cluster) | The config for the terraform-aws-modules/ecs/aws module | <pre>object({<br/>    autoscaling_capacity_providers = optional(any, {})<br/>    cluster_configuration = optional(any, {<br/>      execute_command_configuration = {<br/>        logging = "OVERRIDE"<br/>        log_configuration = {<br/>          cloud_watch_log_group_name = "/aws/ecs/aws-ec2"<br/>        }<br/>      }<br/>    })<br/>    cluster_name = optional(string, "fleet")<br/>    cluster_settings = optional(map(string), {<br/>      "name" : "containerInsights",<br/>      "value" : "enabled",<br/>    })<br/>    create                                = optional(bool, true)<br/>    default_capacity_provider_use_fargate = optional(bool, true)<br/>    fargate_capacity_providers = optional(any, {<br/>      FARGATE = {<br/>        default_capacity_provider_strategy = {<br/>          weight = 100<br/>        }<br/>      }<br/>      FARGATE_SPOT = {<br/>        default_capacity_provider_strategy = {<br/>          weight = 0<br/>        }<br/>      }<br/>    })<br/>    tags = optional(map(string))<br/>  })</pre> | <pre>{<br/>  "autoscaling_capacity_providers": {},<br/>  "cluster_configuration": {<br/>    "execute_command_configuration": {<br/>      "log_configuration": {<br/>        "cloud_watch_log_group_name": "/aws/ecs/aws-ec2"<br/>      },<br/>      "logging": "OVERRIDE"<br/>    }<br/>  },<br/>  "cluster_name": "fleet",<br/>  "cluster_settings": {<br/>    "name": "containerInsights",<br/>    "value": "enabled"<br/>  },<br/>  "create": true,<br/>  "default_capacity_provider_use_fargate": true,<br/>  "fargate_capacity_providers": {<br/>    "FARGATE": {<br/>      "default_capacity_provider_strategy": {<br/>        "weight": 100<br/>      }<br/>    },<br/>    "FARGATE_SPOT": {<br/>      "default_capacity_provider_strategy": {<br/>        "weight": 0<br/>      }<br/>    }<br/>  },<br/>  "tags": {}<br/>}</pre> | no |
| <a name="input_fleet_config"></a> [fleet\_config](#input\_fleet\_config) | The configuration object for Fleet itself. Fields that default to null will have their respective resources created if not specified. | <pre>object({<br/>    task_mem                     = optional(number, null)<br/>    task_cpu                     = optional(number, null)<br/>    mem                          = optional(number, 4096)<br/>    cpu                          = optional(number, 512)<br/>    pid_mode                     = optional(string, null)<br/>    image                        = optional(string, "fleetdm/fleet:v4.64.1")<br/>    family                       = optional(string, "fleet")<br/>    sidecars                     = optional(list(any), [])<br/>    depends_on                   = optional(list(any), [])<br/>    mount_points                 = optional(list(any), [])<br/>    volumes                      = optional(list(any), [])<br/>    extra_environment_variables  = optional(map(string), {})<br/>    extra_iam_policies           = optional(list(string), [])<br/>    extra_execution_iam_policies = optional(list(string), [])<br/>    extra_secrets                = optional(map(string), {})<br/>    security_group_name          = optional(string, "fleet")<br/>    iam_role_arn                 = optional(string, null)<br/>    repository_credentials       = optional(string, "")<br/>    private_key_secret_name      = optional(string, "fleet-server-private-key")<br/>    service = optional(object({<br/>      name = optional(string, "fleet")<br/>      }), {<br/>      name = "fleet"<br/>    })<br/>    database = optional(object({<br/>      password_secret_arn = string<br/>      user                = string<br/>      database            = string<br/>      address             = string<br/>      rr_address          = optional(string, null)<br/>      }), {<br/>      password_secret_arn = null<br/>      user                = null<br/>      database            = null<br/>      address             = null<br/>      rr_address          = null<br/>    })<br/>    redis = optional(object({<br/>      address = string<br/>      use_tls = optional(bool, true)<br/>      }), {<br/>      address = null<br/>      use_tls = true<br/>    })<br/>    awslogs = optional(object({<br/>      name      = optional(string, null)<br/>      region    = optional(string, null)<br/>      create    = optional(bool, true)<br/>      prefix    = optional(string, "fleet")<br/>      retention = optional(number, 5)<br/>      }), {<br/>      name      = null<br/>      region    = null<br/>      prefix    = "fleet"<br/>      retention = 5<br/>    })<br/>    loadbalancer = optional(object({<br/>      arn = string<br/>      }), {<br/>      arn = null<br/>    })<br/>    extra_load_balancers = optional(list(any), [])<br/>    networking = optional(object({<br/>      subnets         = optional(list(string), null)<br/>      security_groups = optional(list(string), null)<br/>      ingress_sources = optional(object({<br/>        cidr_blocks      = optional(list(string), [])<br/>        ipv6_cidr_blocks = optional(list(string), [])<br/>        security_groups  = optional(list(string), [])<br/>        prefix_list_ids  = optional(list(string), [])<br/>        }), {<br/>        cidr_blocks      = []<br/>        ipv6_cidr_blocks = []<br/>        security_groups  = []<br/>        prefix_list_ids  = []<br/>      })<br/>      }), {<br/>      subnets         = null<br/>      security_groups = null<br/>      ingress_sources = {<br/>        cidr_blocks      = []<br/>        ipv6_cidr_blocks = []<br/>        security_groups  = []<br/>        prefix_list_ids  = []<br/>      }<br/>    })<br/>    autoscaling = optional(object({<br/>      max_capacity                 = optional(number, 5)<br/>      min_capacity                 = optional(number, 1)<br/>      memory_tracking_target_value = optional(number, 80)<br/>      cpu_tracking_target_value    = optional(number, 80)<br/>      }), {<br/>      max_capacity                 = 5<br/>      min_capacity                 = 1<br/>      memory_tracking_target_value = 80<br/>      cpu_tracking_target_value    = 80<br/>    })<br/>    iam = optional(object({<br/>      role = optional(object({<br/>        name        = optional(string, "fleet-role")<br/>        policy_name = optional(string, "fleet-iam-policy")<br/>        }), {<br/>        name        = "fleet-role"<br/>        policy_name = "fleet-iam-policy"<br/>      })<br/>      execution = optional(object({<br/>        name        = optional(string, "fleet-execution-role")<br/>        policy_name = optional(string, "fleet-execution-role")<br/>        }), {<br/>        name        = "fleet-execution-role"<br/>        policy_name = "fleet-iam-policy-execution"<br/>      })<br/>      }), {<br/>      name = "fleetdm-execution-role"<br/>    })<br/>    software_installers = optional(object({<br/>      create_bucket    = optional(bool, true)<br/>      bucket_name      = optional(string, null)<br/>      bucket_prefix    = optional(string, "fleet-software-installers-")<br/>      s3_object_prefix = optional(string, "")<br/>      create_kms_key   = optional(bool, false)<br/>      kms_alias        = optional(string, "fleet-software-installers")<br/>      }), {<br/>      create_bucket    = true<br/>      bucket_name      = null<br/>      bucket_prefix    = "fleet-software-installers-"<br/>      s3_object_prefix = ""<br/>      create_kms_key   = false<br/>      kms_alias        = "fleet-software-installers"<br/>    })<br/>  })</pre> | <pre>{<br/>  "autoscaling": {<br/>    "cpu_tracking_target_value": 80,<br/>    "max_capacity": 5,<br/>    "memory_tracking_target_value": 80,<br/>    "min_capacity": 1<br/>  },<br/>  "awslogs": {<br/>    "create": true,<br/>    "name": null,<br/>    "prefix": "fleet",<br/>    "region": null,<br/>    "retention": 5<br/>  },<br/>  "cpu": 256,<br/>  "database": {<br/>    "address": null,<br/>    "database": null,<br/>    "password_secret_arn": null,<br/>    "rr_address": null,<br/>    "user": null<br/>  },<br/>  "depends_on": [],<br/>  "extra_environment_variables": {},<br/>  "extra_execution_iam_policies": [],<br/>  "extra_iam_policies": [],<br/>  "extra_load_balancers": [],<br/>  "extra_secrets": {},<br/>  "family": "fleet",<br/>  "iam": {<br/>    "execution": {<br/>      "name": "fleet-execution-role",<br/>      "policy_name": "fleet-iam-policy-execution"<br/>    },<br/>    "role": {<br/>      "name": "fleet-role",<br/>      "policy_name": "fleet-iam-policy"<br/>    }<br/>  },<br/>  "iam_role_arn": null,<br/>  "image": "fleetdm/fleet:v4.64.1",<br/>  "loadbalancer": {<br/>    "arn": null<br/>  },<br/>  "mem": 512,<br/>  "mount_points": [],<br/>  "networking": {<br/>    "ingress_sources": {<br/>      "cidr_blocks": [],<br/>      "ipv6_cidr_blocks": [],<br/>      "prefix_list_ids": [],<br/>      "security_groups": []<br/>    },<br/>    "security_groups": null,<br/>    "subnets": null<br/>  },<br/>  "pid_mode": null,<br/>  "private_key_secret_name": "fleet-server-private-key",<br/>  "redis": {<br/>    "address": null,<br/>    "use_tls": true<br/>  },<br/>  "repository_credentials": "",<br/>  "security_group_name": "fleet",<br/>  "security_groups": null,<br/>  "service": {<br/>    "name": "fleet"<br/>  },<br/>  "sidecars": [],<br/>  "software_installers": {<br/>    "bucket_name": null,<br/>    "bucket_prefix": "fleet-software-installers-",<br/>    "create_bucket": true,<br/>    "s3_object_prefix": ""<br/>  },<br/>  "task_cpu": null,<br/>  "task_mem": null,<br/>  "volumes": []<br/>}</pre> | no |
| <a name="input_migration_config"></a> [migration\_config](#input\_migration\_config) | The configuration object for Fleet's migration task. | <pre>object({<br/>    mem = number<br/>    cpu = number<br/>  })</pre> | <pre>{<br/>  "cpu": 1024,<br/>  "mem": 2048<br/>}</pre> | no |
| <a name="input_rds_config"></a> [rds\_config](#input\_rds\_config) | The config for the terraform-aws-modules/rds-aurora/aws module | <pre>object({<br/>    name                            = optional(string, "fleet")<br/>    engine_version                  = optional(string, "8.0.mysql_aurora.3.07.1")<br/>    instance_class                  = optional(string, "db.t4g.large")<br/>    subnets                         = optional(list(string), [])<br/>    allowed_security_groups         = optional(list(string), [])<br/>    allowed_cidr_blocks             = optional(list(string), [])<br/>    apply_immediately               = optional(bool, true)<br/>    monitoring_interval             = optional(number, 10)<br/>    db_parameter_group_name         = optional(string)<br/>    db_parameters                   = optional(map(string), {})<br/>    db_cluster_parameter_group_name = optional(string)<br/>    db_cluster_parameters           = optional(map(string), {})<br/>    enabled_cloudwatch_logs_exports = optional(list(string), [])<br/>    master_username                 = optional(string, "fleet")<br/>    snapshot_identifier             = optional(string)<br/>    cluster_tags                    = optional(map(string), {})<br/>    skip_final_snapshot             = optional(bool, true)<br/>    backup_retention_period         = optional(number, 7)<br/>  })</pre> | <pre>{<br/>  "allowed_cidr_blocks": [],<br/>  "allowed_security_groups": [],<br/>  "apply_immediately": true,<br/>  "backup_retention_period": 7,<br/>  "cluster_tags": {},<br/>  "db_cluster_parameter_group_name": null,<br/>  "db_cluster_parameters": {},<br/>  "db_parameter_group_name": null,<br/>  "db_parameters": {},<br/>  "enabled_cloudwatch_logs_exports": [],<br/>  "engine_version": "8.0.mysql_aurora.3.07.1",<br/>  "instance_class": "db.t4g.large",<br/>  "master_username": "fleet",<br/>  "monitoring_interval": 10,<br/>  "name": "fleet",<br/>  "skip_final_snapshot": true,<br/>  "snapshot_identifier": null,<br/>  "subnets": []<br/>}</pre> | no |
| <a name="input_redis_config"></a> [redis\_config](#input\_redis\_config) | n/a | <pre>object({<br/>    name                          = optional(string, "fleet")<br/>    replication_group_id          = optional(string)<br/>    elasticache_subnet_group_name = optional(string)<br/>    allowed_security_group_ids    = optional(list(string), [])<br/>    subnets                       = optional(list(string))<br/>    availability_zones            = optional(list(string))<br/>    cluster_size                  = optional(number, 3)<br/>    instance_type                 = optional(string, "cache.m5.large")<br/>    apply_immediately             = optional(bool, true)<br/>    automatic_failover_enabled    = optional(bool, false)<br/>    engine_version                = optional(string, "6.x")<br/>    family                        = optional(string, "redis6.x")<br/>    at_rest_encryption_enabled    = optional(bool, true)<br/>    transit_encryption_enabled    = optional(bool, true)<br/>    parameter = optional(list(object({<br/>      name  = string<br/>      value = string<br/>    })), [])<br/>    log_delivery_configuration = optional(list(map(any)), [])<br/>    tags                       = optional(map(string), {})<br/>  })</pre> | <pre>{<br/>  "allowed_security_group_ids": [],<br/>  "apply_immediately": true,<br/>  "at_rest_encryption_enabled": true,<br/>  "automatic_failover_enabled": false,<br/>  "availability_zones": null,<br/>  "cluster_size": 3,<br/>  "elasticache_subnet_group_name": null,<br/>  "engine_version": "6.x",<br/>  "family": "redis6.x",<br/>  "instance_type": "cache.m5.large",<br/>  "log_delivery_configuration": [],<br/>  "name": "fleet",<br/>  "parameter": [],<br/>  "replication_group_id": null,<br/>  "subnets": null,<br/>  "tags": {},<br/>  "transit_encryption_enabled": true<br/>}</pre> | no |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | n/a | <pre>object({<br/>    name                = optional(string, "fleet")<br/>    cidr                = optional(string, "10.10.0.0/16")<br/>    azs                 = optional(list(string), ["us-east-2a", "us-east-2b", "us-east-2c"])<br/>    private_subnets     = optional(list(string), ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"])<br/>    public_subnets      = optional(list(string), ["10.10.11.0/24", "10.10.12.0/24", "10.10.13.0/24"])<br/>    database_subnets    = optional(list(string), ["10.10.21.0/24", "10.10.22.0/24", "10.10.23.0/24"])<br/>    elasticache_subnets = optional(list(string), ["10.10.31.0/24", "10.10.32.0/24", "10.10.33.0/24"])<br/><br/>    create_database_subnet_group              = optional(bool, false)<br/>    create_database_subnet_route_table        = optional(bool, true)<br/>    create_elasticache_subnet_group           = optional(bool, true)<br/>    create_elasticache_subnet_route_table     = optional(bool, true)<br/>    enable_vpn_gateway                        = optional(bool, false)<br/>    one_nat_gateway_per_az                    = optional(bool, false)<br/>    single_nat_gateway                        = optional(bool, true)<br/>    enable_nat_gateway                        = optional(bool, true)<br/>    enable_dns_hostnames                      = optional(bool, false)<br/>    enable_dns_support                        = optional(bool, true)<br/>    enable_flow_log                           = optional(bool, false)<br/>    create_flow_log_cloudwatch_log_group      = optional(bool, false)<br/>    create_flow_log_cloudwatch_iam_role       = optional(bool, false)<br/>    flow_log_max_aggregation_interval         = optional(number, 600)<br/>    flow_log_cloudwatch_log_group_name_prefix = optional(string, "/aws/vpc-flow-log/")<br/>    flow_log_cloudwatch_log_group_name_suffix = optional(string, "")<br/>    vpc_flow_log_tags                         = optional(map(string), {})<br/>  })</pre> | <pre>{<br/>  "azs": [<br/>    "us-east-2a",<br/>    "us-east-2b",<br/>    "us-east-2c"<br/>  ],<br/>  "cidr": "10.10.0.0/16",<br/>  "create_database_subnet_group": false,<br/>  "create_database_subnet_route_table": true,<br/>  "create_elasticache_subnet_group": true,<br/>  "create_elasticache_subnet_route_table": true,<br/>  "create_flow_log_cloudwatch_iam_role": false,<br/>  "create_flow_log_cloudwatch_log_group": false,<br/>  "database_subnets": [<br/>    "10.10.21.0/24",<br/>    "10.10.22.0/24",<br/>    "10.10.23.0/24"<br/>  ],<br/>  "elasticache_subnets": [<br/>    "10.10.31.0/24",<br/>    "10.10.32.0/24",<br/>    "10.10.33.0/24"<br/>  ],<br/>  "enable_dns_hostnames": false,<br/>  "enable_dns_support": true,<br/>  "enable_flow_log": false,<br/>  "enable_nat_gateway": true,<br/>  "enable_vpn_gateway": false,<br/>  "flow_log_cloudwatch_log_group_name_prefix": "/aws/vpc-flow-log/",<br/>  "flow_log_cloudwatch_log_group_name_suffix": "",<br/>  "flow_log_max_aggregation_interval": 600,<br/>  "name": "fleet",<br/>  "one_nat_gateway_per_az": false,<br/>  "private_subnets": [<br/>    "10.10.1.0/24",<br/>    "10.10.2.0/24",<br/>    "10.10.3.0/24"<br/>  ],<br/>  "public_subnets": [<br/>    "10.10.11.0/24",<br/>    "10.10.12.0/24",<br/>    "10.10.13.0/24"<br/>  ],<br/>  "single_nat_gateway": true,<br/>  "vpc_flow_log_tags": {}<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_byo-vpc"></a> [byo-vpc](#output\_byo-vpc) | n/a |
| <a name="output_vpc"></a> [vpc](#output\_vpc) | n/a |
