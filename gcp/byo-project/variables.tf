variable "project_id" {
  description = "GCP project ID"
}

variable "allow_destroy" {
  description = "When true, disables deletion protection on all resources. See top-level module for full docs."
  type        = bool
  default     = false
}

variable "location" {
  description = "Location for GCS buckets and the CMEK keyring/crypto key. Defaults to multi-region 'us' for higher availability; set to a specific region (e.g. 'us-central1') for stricter data-residency. Must match between buckets and KMS for CMEK to work."
  type        = string
  default     = "us"
}

variable "region" {
  description = "GCP region for regional-only resources (Cloud Run, Cloud SQL, Memorystore, VPC, LB, Certificate Manager)."
  type        = string
  default     = "us-central1"
}

variable "replicate_secrets" {
  description = "Regions to pin Secret Manager replication to. Empty = automatic replication. See top-level module for full docs."
  type        = list(string)
  default     = []
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

variable "dns_config" {
  description = "DNS configuration. Set enable=false when using external DNS providers or when Cloud DNS is unavailable."
  type = object({
    enable = bool
  })
  default = {
    enable = true
  }
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
    name                = "fleet-mysql-v2"
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
  sensitive = true
  type = object({
    image_tag                       = string
    fleet_cpu                       = string
    fleet_memory                    = string
    debug_logging                   = bool
    license_key                     = optional(string)
    fleet_server_private_key        = optional(string)
    fleet_server_private_key_secret = optional(string)
    min_instance_count              = number
    max_instance_count              = number
    exec_migration                  = bool
    use_h2c                         = bool
    extra_env_vars                  = optional(map(string))
    extra_secret_env_vars = optional(map(object({
      secret  = string
      version = string
    })))
    installers_bucket_name = optional(string)
  })
  default = {
    image_tag              = "fleetdm/fleet:v4.85.0"
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    use_h2c                = false
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
    installers_bucket_name = ""
  }

  validation {
    condition = !(
      var.fleet_config.fleet_server_private_key != null &&
      var.fleet_config.fleet_server_private_key_secret != null
    )
    error_message = "Set at most one of fleet_config.fleet_server_private_key (plaintext) or fleet_config.fleet_server_private_key_secret (existing Secret Manager secret_id). Leave both null to auto-generate."
  }
}

variable "load_balancer_config" {
  description = "Load balancer configuration"
  type = object({
    enable              = optional(bool, true)
    use_regional_lb     = optional(bool, false)
    https_redirect      = optional(bool, true)
    create_managed_cert = optional(bool, true)
    create_static_ip    = optional(bool, false)
    backend_timeout_sec = optional(number, 30)
    log_sample_rate     = optional(number, 1.0)
    proxy_subnet_cidr   = optional(string, "10.129.0.0/23")
  })
}

variable "cloud_armor" {
  description = "Cloud Armor configuration. See top-level module for full docs."
  type = object({
    enable             = optional(bool, false)
    tier               = optional(string, "STANDARD")
    allowed_ip_ranges  = optional(list(string), [])
    allow_public_paths = optional(list(string), [])
  })
  default = {
    enable             = false
    tier               = "STANDARD"
    allowed_ip_ranges  = []
    allow_public_paths = []
  }
}


variable "cmek" {
  description = "Customer-Managed Encryption Key configuration. See top-level module for full docs."
  type = object({
    enable         = optional(bool, false)
    create_kms     = optional(bool, false)
    kms_key_ring   = optional(string)
    kms_crypto_key = optional(string)
  })
  default = {
    enable         = false
    create_kms     = false
    kms_key_ring   = null
    kms_crypto_key = null
  }
}

