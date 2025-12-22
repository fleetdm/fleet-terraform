variable "vpc_id" {
  type = string
}

variable "customer_prefix" {
  type    = string
  default = "fleet"
}

variable "redirect_priority" {
  description = "The priority of the redirect https_listener_rule generated in the output"
  type        = string
  default     = 1
}

variable "trust_store_s3_config" {
  type = object({
    bucket_prefix                      = optional(string, "fleet-okta-trust-store")
    newer_noncurrent_versions          = optional(number, 5)
    noncurrent_version_expiration_days = optional(number, 30)
  })
  default = {
    bucket_prefix                      = "fleet-okta-trust-store"
    newer_noncurrent_versions          = 5
    noncurrent_version_expiration_days = 30
  }
}

variable "alb_config" {
  type = object({
    name                       = optional(string, "fleet-okta")
    subnets                    = list(string)
    security_groups            = optional(list(string), [])
    access_logs                = optional(map(string), {})
    certificate_arn            = string
    allowed_cidrs              = optional(list(string), ["0.0.0.0/0"])
    allowed_ipv6_cidrs         = optional(list(string), ["::/0"])
    egress_cidrs               = optional(list(string), ["0.0.0.0/0"])
    egress_ipv6_cidrs          = optional(list(string), ["::/0"])
    extra_target_groups        = optional(any, [])
    https_listener_rules       = optional(any, [])
    https_overrides            = optional(any, {})
    xff_header_processing_mode = optional(string, null)
    tls_policy                 = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")
    idle_timeout               = optional(number, 60)
    internal                   = optional(bool, false)
    enable_deletion_protection = optional(bool, false)
    subdomain_prefix           = optional(string, "okta")
    trust_store = optional(any, {
      ca_certificates_bundle_s3_key            = "ca.pem"
      ca_certificates_bundle_s3_object_version = null
      ca_certificates_bundle_file              = null
      create_trust_store_revocation            = false
      trust_store_revocation_lists             = {}
    })
  })
}
