# Project Configuration
variable "create_project" {
  description = "Whether to create a new GCP project (true) or use an existing one (false). When true, exactly one of org_id or folder_id must be set, plus billing_account_id."
  type        = bool
  default     = false

  validation {
    condition = !var.create_project || (
      var.billing_account_id != null &&
      (var.org_id != null || var.folder_id != null)
    )
    error_message = "When create_project = true, billing_account_id and at least one of org_id or folder_id must be set."
  }
}

variable "project_id" {
  description = "GCP project ID where Fleet will be deployed. Required when create_project=false. Ignored when create_project=true (the factory generates one)."
  type        = string
  default     = null

  validation {
    condition     = var.create_project || var.project_id != null
    error_message = "project_id must be set when create_project = false."
  }
}

# Variables for project creation (only required when create_project=true)
variable "project_name" {
  description = "Name for the new GCP project"
  type        = string
  default     = "fleet"
}

variable "org_id" {
  description = "GCP Organization ID. Required when create_project=true and folder_id is not set. Ignored when create_project=false."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "GCP Folder ID (numeric, without the 'folders/' prefix). When set with create_project=true, the new project is created under this folder instead of directly under the organization. Ignored when create_project=false."
  type        = string
  default     = null
}

variable "billing_account_id" {
  description = "GCP Billing Account ID (required when create_project=true)"
  type        = string
  default     = null
}

variable "random_project_id" {
  description = "Whether to append a random suffix to project name"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Resource labels to apply to all resources"
  type        = map(string)
  default     = { application = "fleet" }
}

variable "extra_apis" {
  description = "Additional GCP APIs to enable on the project, merged with the baseline set required by Fleet."
  type        = list(string)
  default     = []
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

variable "location" {
  description = <<-EOT
    Defaults to "us" (multi-region) — the higher-availability choice suitable
    for most deployments. Override with a specific region string if you have
    data-residency or compliance requirements that need single-region placement.

    GCS bucket location and KMS key location must match for CMEK to work, so
    both are driven off this single variable.

    Compute/network/DB resources (Cloud Run, Cloud SQL, Memorystore, VPC,
    LB) always use `region`.
  EOT
  type        = string
  default     = "us"
}

variable "replicate_secrets" {
  description = <<-EOT
    Regions to pin Secret Manager replication to (applies to fleet-managed
    secrets: DB password, Fleet server private key, HMAC secret).

    Empty (default) uses `automatic` replication — Google chooses locations,
    fewest constraints, works everywhere. Non-empty switches to
    `user_managed` replication with one replica per region.

    Provide at least two regions if you want cross-region redundancy under
    user_managed (single-region user_managed has no failover).

    NOTE: switching an existing secret between automatic and user_managed
    forces replacement (destroy + recreate).
  EOT
  type        = list(string)
  default     = []
}

variable "region" {
  description = "GCP region for regional-only resources (Cloud Run, Cloud SQL, Memorystore, VPC, LB, Certificate Manager)."
  type        = string
  default     = "us-central1"
}

variable "cache_config" {
  description = "Configuration for the Memorystore (Redis) instance."
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
  description = "Configuration for the Cloud SQL (MySQL) instance."
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
  description = "Configuration for the VPC network and subnets."
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
  description = "Configuration for the Fleet application deployment."
  sensitive   = true
  type = object({
    image_tag                       = string
    fleet_cpu                       = string
    fleet_memory                    = string
    debug_logging                   = bool
    license_key                     = optional(string)
    fleet_server_private_key        = optional(string) # Plaintext (dev/test only). If null and `fleet_server_private_key_secret` is null, a 32-char key is auto-generated.
    fleet_server_private_key_secret = optional(string) # Short secret_id of an existing Secret Manager secret in the same project. Takes precedence over plaintext.
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
}

variable "cmek" {
  description = <<-EOT
    Customer-Managed Encryption Key configuration. When enable = true, resources
    that support CMEK (GCS buckets today; Cloud SQL, Memorystore, etc. in the
    future) can reference the crypto key at local.kms_crypto_key_id.

    When create_kms = true, Terraform creates the key ring and crypto key in the
    target project/region using the provided names. When false, they must already
    exist.
  EOT
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

  validation {
    condition = !var.cmek.enable || (
      var.cmek.kms_key_ring != null && var.cmek.kms_crypto_key != null
    )
    error_message = "When cmek.enable = true, kms_key_ring and kms_crypto_key must both be set."
  }

  validation {
    condition     = !var.cmek.create_kms || var.cmek.enable
    error_message = "cmek.create_kms = true requires cmek.enable = true."
  }
}

variable "allow_destroy" {
  description = <<-EOT
    When true, disables deletion protection on all resources so a full
    `terraform destroy` can proceed:
      - Cloud SQL: deletion_protection = false
      - GCS buckets: force_destroy = true
      - KMS crypto key: prevent_destroy is not enforced (GCP still applies a
        configurable destruction window, default 30 days, before key versions
        are permanently deleted)

    Keep false in production. Set true only when tearing down the environment.
    When allow_destroy overrides database_config.deletion_protection, the more
    permissive value (false) wins.
  EOT
  type        = bool
  default     = false
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
  default = {
    enable              = true
    use_regional_lb     = false
    https_redirect      = true
    create_managed_cert = true
    create_static_ip    = false
    backend_timeout_sec = 30
    log_sample_rate     = 1.0
    proxy_subnet_cidr   = "10.129.0.0/23"
  }
}

variable "cloud_armor" {
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

  validation {
    condition     = contains(["STANDARD", "ENTERPRISE"], var.cloud_armor.tier)
    error_message = "cloud_armor.tier must be one of: STANDARD, ENTERPRISE."
  }

  validation {
    condition     = var.cloud_armor.tier != "ENTERPRISE" || !var.cloud_armor.enable
    error_message = "cloud_armor.tier = ENTERPRISE is not yet implemented in this module. Set tier = STANDARD or leave cloud_armor.enable = false."
  }

  validation {
    condition = !var.cloud_armor.enable || (
      var.load_balancer_config.enable && var.load_balancer_config.use_regional_lb
    )
    error_message = "cloud_armor.enable = true requires load_balancer_config.enable = true and load_balancer_config.use_regional_lb = true. Cloud Armor is only wired for the regional LB path in this module."
  }
}

