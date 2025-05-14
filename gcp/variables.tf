variable "project_name" {
  default = "fleet"
}

variable "org_id" {
  description = "organization id"
}

variable "billing_account_id" {
  description = "billing account id"
}

variable "labels" {
  description = "resource labels"
  default     = {application = "fleet"}
  type        = map(string)
}

variable "fleet_image" {
  default = "v4.67.3"
}

variable "dns_zone_name" {
  description = "The DNS name of the managed zone (e.g., 'my-fleet-infra.com.')"
  type        = string
}

variable "dns_record_name" {
  description = "The DNS record for Fleet (e.g., 'fleet.my-fleet-infra.com.')"
  type        = string
}

variable "random_project_id" {
  default = true
}