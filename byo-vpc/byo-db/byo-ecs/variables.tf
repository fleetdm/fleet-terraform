variable "ecs_cluster" {
  type        = string
  description = "The name of the ECS cluster to use"
  nullable    = false
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "kms_base_policy" {
  type = list(object({
    sid    = string
    effect = string
    principals = object({
      type        = string
      identifiers = list(string)
    })
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default     = null
  description = "Optional base KMS key-policy statements to apply to module-created CMKs before module-required service access statements are merged in. If null, the module defaults to the historical root `kms:*` statement."
}

variable "fleet_config" {
  type = object({
    task_mem = optional(number, null)
    task_cpu = optional(number, null)
    ephemeral_storage = optional(object({
      size_in_gib = number
    }), null)
    mem                          = optional(number, 4096)
    cpu                          = optional(number, 512)
    pid_mode                     = optional(string, null)
    image                        = optional(string, "fleetdm/fleet:v4.81.2")
    family                       = optional(string, "fleet")
    sidecars                     = optional(list(any), [])
    depends_on                   = optional(list(any), [])
    mount_points                 = optional(list(any), [])
    volumes                      = optional(list(any), [])
    extra_environment_variables  = optional(map(string), {})
    extra_iam_policies           = optional(list(string), [])
    extra_execution_iam_policies = optional(list(string), [])
    extra_secrets                = optional(map(string), {})
    security_group_name          = optional(string, "fleet")
    iam_role_arn                 = optional(string, null)
    repository_credentials       = optional(string, "")
    private_key_secret_name      = optional(string, "fleet-server-private-key")
    private_key_secret_kms = optional(object({
      cmk_enabled        = optional(bool, null)
      enabled            = optional(bool, null)
      kms_key_arn        = optional(string, null)
      kms_alias          = optional(string, "fleet-server-private-key")
      extra_kms_policies = optional(list(any), [])
      }), {
      cmk_enabled        = null
      enabled            = null
      kms_key_arn        = null
      kms_alias          = "fleet-server-private-key"
      extra_kms_policies = []
    })
    server_tls_enabled = optional(bool, false)
    service = optional(object({
      name = optional(string, "fleet")
      }), {
      name = "fleet"
    })
    database = object({
      password_secret_arn         = string
      password_secret_kms_key_arn = optional(string, null)
      user                        = string
      database                    = string
      address                     = string
      rr_address                  = optional(string, null)
    })
    redis = object({
      address = string
      use_tls = optional(bool, true)
    })
    awslogs = optional(object({
      name      = optional(string, null)
      region    = optional(string, null)
      create    = optional(bool, true)
      prefix    = optional(string, "fleet")
      retention = optional(number, 5)
      kms = optional(object({
        cmk_enabled        = optional(bool, null)
        enabled            = optional(bool, null)
        kms_key_arn        = optional(string, null)
        kms_alias          = optional(string, "fleet-application-logs")
        extra_kms_policies = optional(list(any), [])
        }), {
        cmk_enabled        = null
        enabled            = null
        kms_key_arn        = null
        kms_alias          = "fleet-application-logs"
        extra_kms_policies = []
      })
      }), {
      name      = null
      region    = null
      create    = true
      prefix    = "fleet"
      retention = 5
      kms = {
        cmk_enabled        = null
        enabled            = null
        kms_key_arn        = null
        kms_alias          = "fleet-application-logs"
        extra_kms_policies = []
      }
    })
    loadbalancer = object({
      arn = string
    })
    extra_load_balancers = optional(list(any), [])
    networking = object({
      subnets         = optional(list(string), null)
      security_groups = optional(list(string), null)
      ingress_sources = object({
        cidr_blocks      = optional(list(string), [])
        ipv6_cidr_blocks = optional(list(string), [])
        security_groups  = optional(list(string), [])
        prefix_list_ids  = optional(list(string), [])
      })
      assign_public_ip = optional(bool, false)
    })
    autoscaling = optional(object({
      max_capacity                 = optional(number, 5)
      min_capacity                 = optional(number, 1)
      memory_tracking_target_value = optional(number, 80)
      cpu_tracking_target_value    = optional(number, 80)
      }), {
      max_capacity                 = 5
      min_capacity                 = 1
      memory_tracking_target_value = 80
      cpu_tracking_target_value    = 80
    })
    iam = optional(object({
      role = optional(object({
        name        = optional(string, "fleet-role")
        policy_name = optional(string, "fleet-iam-policy")
        }), {
        name        = "fleet-role"
        policy_name = "fleet-iam-policy"
      })
      execution = optional(object({
        name        = optional(string, "fleet-execution-role")
        policy_name = optional(string, "fleet-execution-role")
        }), {
        name        = "fleet-execution-role"
        policy_name = "fleet-iam-policy-execution"
      })
      }), {
      name = "fleetdm-execution-role"
    })
    software_installers = optional(object({
      create_bucket                      = optional(bool, true)
      bucket_name                        = optional(string, null)
      bucket_prefix                      = optional(string, "fleet-software-installers-")
      s3_object_prefix                   = optional(string, "")
      cloudfront_distribution_arn        = optional(string, null)
      enable_bucket_versioning           = optional(bool, false)
      expire_noncurrent_versions         = optional(bool, true)
      noncurrent_version_expiration_days = optional(number, 30)
      create_kms_key                     = optional(bool, false)
      kms_key_arn                        = optional(string, null)
      kms_alias                          = optional(string, "fleet-software-installers")
      extra_kms_policies                 = optional(list(any), [])
      tags                               = optional(map(string), {})
      }), {
      create_bucket                      = true
      bucket_name                        = null
      bucket_prefix                      = "fleet-software-installers-"
      s3_object_prefix                   = ""
      cloudfront_distribution_arn        = null
      enable_bucket_versioning           = false
      expire_noncurrent_versions         = true
      noncurrent_version_expiration_days = 30
      create_kms_key                     = false
      kms_key_arn                        = null
      kms_alias                          = "fleet-software-installers"
      extra_kms_policies                 = []
      tags                               = {}
    })
  })
  default = {
    task_mem                     = null
    task_cpu                     = null
    ephemeral_storage            = null
    mem                          = 512
    cpu                          = 256
    pid_mode                     = null
    image                        = "fleetdm/fleet:v4.81.2"
    family                       = "fleet"
    sidecars                     = []
    depends_on                   = []
    mount_points                 = []
    volumes                      = []
    extra_environment_variables  = {}
    extra_iam_policies           = []
    extra_execution_iam_policies = []
    extra_secrets                = {}
    security_group_name          = "fleet"
    iam_role_arn                 = null
    repository_credentials       = ""
    private_key_secret_name      = "fleet-server-private-key"
    private_key_secret_kms = {
      cmk_enabled        = null
      enabled            = null
      kms_key_arn        = null
      kms_alias          = "fleet-server-private-key"
      extra_kms_policies = []
    }
    server_tls_enabled = false
    service = {
      name = "fleet"
    }
    database = {
      password_secret_arn = null
      user                = null
      database            = null
      address             = null
      rr_address          = null
    }
    redis = {
      address = null
      use_tls = true
    }
    awslogs = {
      name      = null
      region    = null
      create    = true
      prefix    = "fleet"
      retention = 5
      kms = {
        cmk_enabled        = null
        enabled            = null
        kms_key_arn        = null
        kms_alias          = "fleet-application-logs"
        extra_kms_policies = []
      }
    }
    loadbalancer = {
      arn = null
    }
    extra_load_balancers = []
    networking = {
      subnets         = null
      security_groups = null
      ingress_sources = {
        cidr_blocks      = []
        ipv6_cidr_blocks = []
        security_groups  = []
        prefix_list_ids  = []
      }
      assign_public_ip = false
    }
    autoscaling = {
      max_capacity                 = 5
      min_capacity                 = 1
      memory_tracking_target_value = 80
      cpu_tracking_target_value    = 80
    }
    iam = {
      role = {
        name        = "fleet-role"
        policy_name = "fleet-iam-policy"
      }
      execution = {
        name        = "fleet-execution-role"
        policy_name = "fleet-iam-policy-execution"
      }
    }
    software_installers = {
      create_bucket                      = true
      bucket_name                        = null
      bucket_prefix                      = "fleet-software-installers-"
      s3_object_prefix                   = ""
      cloudfront_distribution_arn        = null
      enable_bucket_versioning           = false
      expire_noncurrent_versions         = true
      noncurrent_version_expiration_days = 30
      create_kms_key                     = false
      kms_key_arn                        = null
      kms_alias                          = "fleet-software-installers"
      extra_kms_policies                 = []
      tags                               = {}
    }
  }
  description = "The configuration object for Fleet itself. Fields that default to null will have their respective resources created if not specified. For published KMS blocks, legacy `enabled` is deprecated and still accepted; prefer `cmk_enabled`."
  nullable    = false
  validation {
    condition     = var.fleet_config.ephemeral_storage == null ? true : (var.fleet_config.ephemeral_storage.size_in_gib >= 21 && var.fleet_config.ephemeral_storage.size_in_gib <= 200)
    error_message = "fleet_config.ephemeral_storage.size_in_gib must be between 21 and 200 GiB when set."
  }
}

variable "migration_config" {
  type = object({
    mem = number
    cpu = number
  })
  default = {
    mem = 2048
    cpu = 1024
  }
  description = "The configuration object for Fleet's migration task."
  nullable    = false
}
