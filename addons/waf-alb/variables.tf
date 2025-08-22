variable "name" {}

variable "lb_arn" {}

variable "waf_type" {
  type    = string
  default = "blocklist"
}

variable "blocked_countries" {
  type    = list(string)
  default = ["BI", "BY", "CD", "CF", "CU", "IQ", "IR", "LB", "LY", "SD", "SO", "SS", "SY", "VE", "ZW", "RU"]
}

variable "blocked_addresses" {
  type    = list(string)
  default = []
}

variable "allowed_addresses" {
  type    = list(string)
  default = []
}

variable "capacity" {
  description = "The capacity required to handle the rules."
  type        = number
  default     = 2
}

variable "bypass_urls" {
  description = <<EOT
Optional list of regex patterns for URL paths that bypass the IP allowlist WAF rule.
The patterns must be valid AWS WAF regex strings.
EOT
  type    = list(string)
  default = []
}
