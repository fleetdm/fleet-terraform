# Project Configuration
variable "create_project" {
  description = "Whether to create a new GCP project (true) or use an existing one (false). When true, org_id or folder_id must be set, plus billing_account_id; folder_id takes precedence when both are provided."
  type        = bool
  default     = true

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

# Legacy inputs were not forwarded to byo-project. Keep accepting them so
# existing -var arguments and tfvars remain compatible, without changing names.
variable "prefix" {
  description = "Legacy no-op input retained for compatibility. The child module uses its own prefix default."
  type        = string
  default     = "fleet"
}

variable "fleet_image" {
  description = "Legacy no-op input retained for compatibility. Use fleet_config.image_tag to select the Fleet image."
  type        = string
  default     = "v4.67.3"
}

variable "labels" {
  description = "Resource labels to apply to all resources"
  type        = map(string)
  default     = { application = "fleet" }
}

variable "extra_apis" {
  description = "Additional GCP APIs merged with the Fleet baseline when create_project = true, or when manage_existing_project_apis = true on an existing project. Otherwise existing-project API enablement remains operator-managed."
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
    image_tag              = "fleetdm/fleet:v4.93.0"
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
    Customer-Managed Encryption Key configuration. When enable = true, the GCS
    buckets are encrypted with the crypto key at local.kms_crypto_key_id
    (located at var.location).

    When create_kms = true, Terraform creates the key ring and crypto key in the
    target project/region using the provided names. When false, they must already
    exist. These legacy settings only ever encrypt the GCS buckets.

    Optional, independent opt-ins (default null = Google-managed, unchanged):
      cloud_sql      = { kms_key_id = "<full key ID in var.region>" }
      redis          = { kms_key_id = "<full key ID in var.region>" }
      cloud_run      = { kms_key_id = "<full key ID in var.region>" }
      secret_manager = {
        kms_key_id          = "<global key ID>"       # automatic replication
        replica_kms_key_ids = { "<region>" = "<key>" } # one per replicate_secrets region
      }
    Keys are never created for these; callers supply existing keys (or keys
    managed elsewhere in their configuration). Terraform grants the Cloud SQL,
    Memorystore, Cloud Run and Secret Manager service agents
    roles/cloudkms.cryptoKeyEncrypterDecrypter on them. Enabling cloud_sql or
    redis on an existing deployment replaces the instance; enabling
    secret_manager replaces the Fleet-managed secrets.
  EOT
  type = object({
    enable         = optional(bool, false)
    create_kms     = optional(bool, false)
    kms_key_ring   = optional(string)
    kms_crypto_key = optional(string)
    cloud_sql = optional(object({
      kms_key_id = string
    }))
    redis = optional(object({
      kms_key_id = string
    }))
    cloud_run = optional(object({
      kms_key_id = string
    }))
    secret_manager = optional(object({
      kms_key_id          = optional(string)
      replica_kms_key_ids = optional(map(string), {})
    }))
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
    When true, permits teardown of protected Cloud SQL and non-empty GCS buckets:
      - Cloud SQL: deletion_protection = false
      - GCS buckets: force_destroy = true (deletes objects when destroying a bucket)

    This does not control KMS key protection or GCP's key-version destruction window.

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

  validation {
    condition = !(
      var.load_balancer_config.enable &&
      var.load_balancer_config.use_regional_lb &&
      var.load_balancer_config.https_redirect &&
      !var.load_balancer_config.create_managed_cert
    )
    error_message = "load_balancer_config.https_redirect = true with use_regional_lb = true requires create_managed_cert = true. Without the managed certificate the regional LB has no HTTPS listener to redirect to; set https_redirect = false or create_managed_cert = true."
  }
}

variable "cloud_armor" {
  description = <<-EOT
    Optional Cloud Armor allowlist for the regional load balancer (off by default).
    When enable = true the policy allows requests from any source in allowed_ip_ranges (any path),
    and requests to any path matching an RE2 regex in allow_public_paths (any source).
    All other requests are denied with HTTP 403. No Fleet endpoints are allowed automatically;
    at least one of allowed_ip_ranges or allow_public_paths must be non-empty when enabled.
    Requires load_balancer_config.enable = true and use_regional_lb = true.
    Attachment is managed natively with google-beta; no gcloud CLI is required.
    Only tier = STANDARD is implemented; the legacy tier field is retained for compatibility.
  EOT
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

  # The policy ends in a deny-all rule, so an enabled policy with nothing
  # allowed would return 403 for every request (admins and devices alike).
  validation {
    condition     = !var.cloud_armor.enable || length(var.cloud_armor.allowed_ip_ranges) + length(var.cloud_armor.allow_public_paths) > 0
    error_message = "cloud_armor.enable = true requires at least one entry in cloud_armor.allowed_ip_ranges or cloud_armor.allow_public_paths. With both empty the policy would deny all traffic (403). No Fleet endpoints are allowed automatically."
  }
}

