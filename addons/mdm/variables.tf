variable "apn_secret_name" {
  default  = "fleet-apn"
  nullable = true
  type     = string
}

variable "scep_secret_name" {
  default  = "fleet-scep"
  nullable = false
  type     = string
}

variable "abm_secret_name" {
  default  = "fleet-abm"
  nullable = true
  type     = string
}

variable "enable_windows_mdm" {
  default  = false
  nullable = false
  type     = bool
}

variable "enable_apple_mdm" {
  default  = true
  nullable = false
  type     = bool
}

variable "secrets_kms" {
  description = "Configuration for optional customer-managed KMS encryption of the MDM Secrets Manager secrets."
  type = object({
    cmk_enabled = optional(bool, false)
    kms_key_arn = optional(string, null)
    kms_alias   = optional(string, "fleet-mdm-secrets")
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
    extra_kms_policies        = optional(list(any), [])
    fleet_execution_role_name = optional(string, null)
  })
  default = {
    cmk_enabled               = false
    kms_key_arn               = null
    kms_alias                 = "fleet-mdm-secrets"
    kms_base_policy           = null
    extra_kms_policies        = []
    fleet_execution_role_name = null
  }

  validation {
    condition = (
      var.secrets_kms.kms_key_arn == null ||
      var.secrets_kms.cmk_enabled == true
    )
    error_message = "secrets_kms.kms_key_arn requires secrets_kms.cmk_enabled = true."
  }

  validation {
    condition = (
      length(var.secrets_kms.extra_kms_policies) == 0 ||
      (
        var.secrets_kms.cmk_enabled == true &&
        var.secrets_kms.kms_key_arn == null
      )
    )
    error_message = "secrets_kms.extra_kms_policies can be set only when the mdm module is creating the secrets CMK."
  }

  validation {
    condition = (
      var.secrets_kms.kms_base_policy == null ||
      (
        var.secrets_kms.cmk_enabled == true &&
        var.secrets_kms.kms_key_arn == null
      )
    )
    error_message = "secrets_kms.kms_base_policy can be set only when the mdm module is creating the secrets CMK."
  }

  validation {
    condition = (
      var.secrets_kms.fleet_execution_role_name == null ||
      trimspace(var.secrets_kms.fleet_execution_role_name) == "" ||
      (
        var.secrets_kms.cmk_enabled == true &&
        var.secrets_kms.kms_key_arn == null
      )
    )
    error_message = "secrets_kms.fleet_execution_role_name can be set only when the mdm module is creating the secrets CMK."
  }
}
