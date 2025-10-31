variable "domain" {
  type        = string
  description = "Domain to use for SES."
}

variable "zone_id" {
  type        = string
  description = "Route53 Zone ID"
}

variable "extra_txt_records" {
  type        = list(string)
  description = "Extra TXT records that have to match the same name as the Fleet instance"
  default     = []
}

variable "custom_mail_from" {
  type = object({
    enabled       = optional(bool, false)
    domain_prefix = optional(string, "")
  })
  default = {
    enabled       = false
    domain_prefix = ""
  }
  description = "Custom MAIL FROM domain settings"
}

variable "create_iam_policy" {
  type        = bool
  default     = true
  description = "Create IAM policy for the SES email sending. (Default: true)"
}