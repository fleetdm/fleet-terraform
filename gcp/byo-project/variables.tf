variable "project_id" {
  description = "GCP project ID"
}

variable "allow_destroy" {
  description = "When true, disables Cloud SQL deletion protection and allows destroying non-empty GCS buckets. Does not control KMS protection. See top-level module for full docs."
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
  default = {}

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
  description = "Cloud Armor allowlist configuration (off by default). allowed_ip_ranges may reach any path; allow_public_paths (RE2 regexes) are reachable from any source; everything else is denied with 403. See the top-level module for full docs."
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

  # Mirrors the root module check: an enabled policy with nothing allowed
  # would deny all traffic with 403.
  validation {
    condition     = !var.cloud_armor.enable || length(var.cloud_armor.allowed_ip_ranges) + length(var.cloud_armor.allow_public_paths) > 0
    error_message = "cloud_armor.enable = true requires at least one entry in cloud_armor.allowed_ip_ranges or cloud_armor.allow_public_paths. With both empty the policy would deny all traffic (403). No Fleet endpoints are allowed automatically."
  }
}


variable "cmek" {
  description = <<-EOT
    Customer-Managed Encryption Key configuration. See top-level module for full docs.

    enable/create_kms/kms_key_ring/kms_crypto_key are the legacy settings and
    only ever encrypt the GCS buckets (key at var.location).

    cloud_sql, redis, cloud_run and secret_manager are independent opt-ins
    (default null = Google-managed encryption, unchanged behavior). Each takes a
    full, caller-supplied crypto key resource ID
    (projects/P/locations/L/keyRings/R/cryptoKeys/K); this module never creates
    those keys, it only grants the matching Google service agent
    roles/cloudkms.cryptoKeyEncrypterDecrypter on them.
      - cloud_sql/redis/cloud_run: key location must equal var.region.
        Enabling on an existing Cloud SQL or Redis instance REPLACES it.
      - secret_manager with empty replicate_secrets (automatic replication):
        kms_key_id must be a global key; replica_kms_key_ids must be empty.
      - secret_manager with replicate_secrets set (user-managed replication):
        kms_key_id must be null and replica_kms_key_ids must map exactly every
        replicate_secrets region to a key in that region.
        Enabling on existing managed secrets replaces them (same secret IDs).
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

  # Each check is written so a null consumer passes and an unknown
  # (caller-created) key ID leaves the result unknown, deferring the check to
  # apply instead of failing the plan.
  validation {
    condition     = var.cmek.cloud_sql == null || can(regex("^projects/[^/]+/locations/${var.region}/keyRings/[^/]+/cryptoKeys/[^/]+$", var.cmek.cloud_sql.kms_key_id))
    error_message = "cmek.cloud_sql.kms_key_id must be a full crypto key ID (projects/P/locations/L/keyRings/R/cryptoKeys/K) located in var.region."
  }

  validation {
    condition     = var.cmek.redis == null || can(regex("^projects/[^/]+/locations/${var.region}/keyRings/[^/]+/cryptoKeys/[^/]+$", var.cmek.redis.kms_key_id))
    error_message = "cmek.redis.kms_key_id must be a full crypto key ID (projects/P/locations/L/keyRings/R/cryptoKeys/K) located in var.region."
  }

  validation {
    condition     = var.cmek.cloud_run == null || can(regex("^projects/[^/]+/locations/${var.region}/keyRings/[^/]+/cryptoKeys/[^/]+$", var.cmek.cloud_run.kms_key_id))
    error_message = "cmek.cloud_run.kms_key_id must be a full crypto key ID (projects/P/locations/L/keyRings/R/cryptoKeys/K) located in var.region."
  }

  validation {
    condition     = var.cmek.secret_manager == null || length(var.replicate_secrets) > 0 || can(regex("^projects/[^/]+/locations/global/keyRings/[^/]+/cryptoKeys/[^/]+$", var.cmek.secret_manager.kms_key_id))
    error_message = "With automatic secret replication (replicate_secrets empty), cmek.secret_manager.kms_key_id must be a full crypto key ID in location global."
  }

  validation {
    condition     = var.cmek.secret_manager == null || length(var.replicate_secrets) > 0 || length(try(var.cmek.secret_manager.replica_kms_key_ids, {})) == 0
    error_message = "With automatic secret replication (replicate_secrets empty), cmek.secret_manager.replica_kms_key_ids must be empty; use kms_key_id with a global key."
  }

  validation {
    condition     = var.cmek.secret_manager == null || length(var.replicate_secrets) == 0 || try(var.cmek.secret_manager.kms_key_id == null, false)
    error_message = "With user-managed secret replication (replicate_secrets set), cmek.secret_manager.kms_key_id must be null; set one key per region in replica_kms_key_ids."
  }

  validation {
    condition = var.cmek.secret_manager == null || length(var.replicate_secrets) == 0 || try(
      length(setsubtract(toset(var.replicate_secrets), keys(var.cmek.secret_manager.replica_kms_key_ids))) == 0 &&
      length(setsubtract(keys(var.cmek.secret_manager.replica_kms_key_ids), toset(var.replicate_secrets))) == 0,
      false
    )
    error_message = "cmek.secret_manager.replica_kms_key_ids must have exactly one entry per replicate_secrets region (no missing or extra regions), so no replica is left Google-managed."
  }

  validation {
    condition = alltrue([
      for r, k in try(var.cmek.secret_manager.replica_kms_key_ids, {}) :
      can(regex("^projects/[^/]+/locations/${r}/keyRings/[^/]+/cryptoKeys/[^/]+$", k))
    ])
    error_message = "Each cmek.secret_manager.replica_kms_key_ids value must be a full crypto key ID located in the region given by its map key."
  }
}

