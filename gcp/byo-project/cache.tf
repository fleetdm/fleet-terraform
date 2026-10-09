module "memstore" {
  source  = "terraform-google-modules/memorystore/google"
  version = "~> 14.0"

  name           = var.cache_config.name
  redis_version  = var.cache_config.engine_version
  tier           = var.cache_config.tier
  memory_size_gb = var.cache_config.memory_size

  project_id              = var.project_id
  region                  = var.region
  enable_apis             = true
  transit_encryption_mode = "DISABLED"
  authorized_network      = module.vpc.network_id
  connect_mode            = var.cache_config.connect_mode

  # Opt-in CMEK (cmek.redis). null = Google-managed (unchanged default).
  # ForceNew: setting or changing this on an existing instance replaces it.
  # In-transit encryption (transit_encryption_mode) is intentionally unchanged.
  customer_managed_key = local.cmek_redis_key_id

  # The Redis service agent must be able to use the key before the instance
  # is created (no-op when cmek.redis is null).
  depends_on = [
    module.private-service-access.peering_completed,
    google_kms_crypto_key_iam_member.redis_cmek,
  ]
}