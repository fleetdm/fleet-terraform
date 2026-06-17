variable "customer_prefix" {
  type    = string
  default = "fleet"
}

variable "fleet_ecs_service_name" {
  type    = string
  default = null
}

variable "albs" {
  type = list(object({
    name                    = string
    arn_suffix              = string
    target_group_name       = string
    target_group_arn_suffix = string
    min_containers          = optional(string, 1)
    ecs_service_name        = string
    alert_thresholds = optional(
      object({
        HTTPCode_ELB_5XX_Count = object({
          period    = number
          threshold = number
        })
        HTTPCode_Target_5XX_Count = object({
          period    = number
          threshold = number
        })
      }),
      {
        HTTPCode_ELB_5XX_Count = {
          period    = 120
          threshold = 0
        },
        HTTPCode_Target_5XX_Count = {
          period    = 120
          threshold = 0
        }
      }
    )
  }))
  default = []
}


variable "default_sns_topic_arns" {
  type    = list(string)
  default = []
}

variable "sns_topic_arns_map" {
  type    = map(list(string))
  default = {}
}

variable "mysql_cluster_members" {
  type    = list(string)
  default = []
}

variable "redis_cluster_members" {
  type    = list(string)
  default = []
}

variable "acm_certificate_arn" {
  type    = string
  default = null
}

variable "log_monitoring" {
  description = "Map of CloudWatch log monitors to create. Key is used as a suffix for resources and metric naming."
  type = map(object({
    log_group_name     = string
    pattern            = string
    evaluation_periods = number
    period             = number
    threshold          = number
  }))
  default = {}
}

variable "alert_thresholds" {
  description = "CloudWatch alarm threshold overrides. Each alarm type is optional; omitted fields use the defaults below."
  type = object({
    rds_cpu = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 80
      period             = 300
      evaluation_periods = 1
    })
    redis_cpu = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 70
      period             = 300
      evaluation_periods = 1
    })
    redis_cpu_engine = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 25
      period             = 300
      evaluation_periods = 1
    })
    redis_memory = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 80
      period             = 300
      evaluation_periods = 1
    })
    acm_cert_expiry = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 30
      period             = 86400
      evaluation_periods = 1
    })
    alb_healthyhosts = optional(object({
      threshold          = number
      period             = number
      evaluation_periods = number
      }), {
      threshold          = 1
      period             = 60
      evaluation_periods = 1
    })
  })
  default = {
    rds_cpu = {
      threshold          = 80
      period             = 300
      evaluation_periods = 1
    }
    redis_cpu = {
      threshold          = 70
      period             = 300
      evaluation_periods = 1
    }
    redis_cpu_engine = {
      threshold          = 25
      period             = 300
      evaluation_periods = 1
    }
    redis_memory = {
      threshold          = 80
      period             = 300
      evaluation_periods = 1
    }
    acm_cert_expiry = {
      threshold          = 30
      period             = 86400
      evaluation_periods = 1
    }
    alb_healthyhosts = {
      threshold          = 1
      period             = 60
      evaluation_periods = 1
    }
  }
}

variable "cron_monitoring" {
  type = object({
    mysql_host                        = string
    mysql_database                    = string
    mysql_user                        = string
    mysql_password_secret_name        = string
    mysql_password_secret_kms_key_arn = optional(string, null)
    mysql_tls_config                  = optional(string, "true")
    vpc_id                            = string
    subnet_ids                        = list(string)
    rds_security_group_id             = string
    delay_tolerance                   = string
    run_interval                      = string
    log_retention_in_days             = optional(number, 7)
    ignore_list                       = optional(list(string), [])
    lambda_kms = optional(object({
      cmk_enabled = optional(bool, false)
      kms_key_arn = optional(string, null)
      kms_alias   = optional(string, "fleet-cron-monitoring")
      kms_base_policy = optional(list(object({
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
      })), null)
      extra_kms_policies = optional(list(any), [])
      }), {
      cmk_enabled        = false
      kms_key_arn        = null
      kms_alias          = "fleet-cron-monitoring"
      kms_base_policy    = null
      extra_kms_policies = []
    })
  })
  default = null

  validation {
    condition = (
      var.cron_monitoring == null ||
      var.cron_monitoring.lambda_kms.kms_key_arn == null ||
      var.cron_monitoring.lambda_kms.cmk_enabled == true
    )
    error_message = "cron_monitoring.lambda_kms.kms_key_arn requires cron_monitoring.lambda_kms.cmk_enabled = true."
  }

  validation {
    condition = (
      var.cron_monitoring == null ||
      length(var.cron_monitoring.lambda_kms.extra_kms_policies) == 0 ||
      (
        var.cron_monitoring.lambda_kms.cmk_enabled == true &&
        var.cron_monitoring.lambda_kms.kms_key_arn == null
      )
    )
    error_message = "cron_monitoring.lambda_kms.extra_kms_policies can be set only when the monitoring module is creating the cron monitoring Lambda CMK."
  }

  validation {
    condition = (
      var.cron_monitoring == null ||
      var.cron_monitoring.lambda_kms.kms_base_policy == null ||
      (
        var.cron_monitoring.lambda_kms.cmk_enabled == true &&
        var.cron_monitoring.lambda_kms.kms_key_arn == null
      )
    )
    error_message = "cron_monitoring.lambda_kms.kms_base_policy can be set only when the monitoring module is creating the cron monitoring Lambda CMK."
  }
}
