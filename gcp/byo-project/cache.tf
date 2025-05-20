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

  depends_on = [module.private-service-access.peering_completed]
}