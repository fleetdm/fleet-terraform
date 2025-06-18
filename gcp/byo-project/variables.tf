variable "project_id" {
  description = "GCP project ID"
}

variable "location" {
  default = "us"
}

variable "region" {
  default = "us-central1"
}

variable "prefix" {
  default = "fleet"
}

variable "dns_zone_name" {
  description = "The DNS name of the managed zone (e.g., 'my-fleet-infra.com.')"
  type        = string
}

variable "dns_record_name" {
  description = "The DNS record for Fleet (e.g., 'fleet.my-fleet-infra.com.')"
  type        = string
}

variable "cache_config" {
  type = object({
    name           = string
    tier           = string
    engine_version = string
    connect_mode   = string
    memory_size    = number
  })
  default = {
    name           = "fleet-cache"
    tier           = "STANDARD_HA"
    engine_version = null // defaults to version 7
    connect_mode   = "PRIVATE_SERVICE_ACCESS"
    memory_size    = 1
  }
}

variable "database_config" {
  type = object({
    name                = string
    database_name       = string
    database_user       = string
    collation           = string
    charset             = string
    deletion_protection = bool
    database_version    = string
    tier                = string
  })
  default = {
    name                = "fleet-mysql"
    database_name       = "fleet"
    database_user       = "fleet"
    collation           = "utf8mb4_unicode_ci"
    charset             = "utf8mb4"
    deletion_protection = false
    database_version    = "MYSQL_8_0"
    tier                = "db-n1-standard-1"
  }
}

variable "vpc_config" {
  type = object({
    network_name = string
    subnets = list(object({
      subnet_name           = string
      subnet_ip             = string
      subnet_region         = string
      subnet_private_access = bool
    }))
  })

  default = {
    network_name = "fleet-network"
    subnets = [
      {
        subnet_name           = "fleet-subnet"
        subnet_ip             = "10.10.10.0/24"
        subnet_region         = "us-central1"
        subnet_private_access = true
      }
    ]
  }

}
variable "fleet_config" {
  type = object({
    installers_bucket_name = string
    image_tag              = string
    fleet_cpu              = string
    fleet_memory           = string
    debug_logging          = bool
    license_key            = optional(string)
    min_instance_count     = number
    max_instance_count     = number
    exec_migration         = bool
    extra_env_vars         = optional(map(string))
    extra_secret_env_vars = optional(map(object({
      secret  = string
      version = string
    })))
  })
  default = {
    image_tag              = "fleetdm/fleet:v4.67.3"
    installers_bucket_name = ""
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
  }
}
