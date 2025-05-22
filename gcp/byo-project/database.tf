resource "random_id" "suffix" {
  byte_length = 5
}


module "private-service-access" {
  source  = "terraform-google-modules/sql-db/google//modules/private_service_access"
  version = "~> 25.0"

  project_id      = var.project_id
  vpc_network     = module.vpc.network_name
  deletion_policy = "ABANDON"
}

module "mysql" {
  source  = "terraform-google-modules/sql-db/google//modules/mysql"
  version = "~> 25.0"

  name                 = var.database_config.name
  project_id           = var.project_id
  deletion_protection  = var.database_config.deletion_protection
  database_version     = var.database_config.database_version
  tier                 = var.database_config.tier
  region               = var.region
  random_instance_name = true
  enable_default_user  = true
  enable_default_db    = true
  user_name            = var.database_config.database_user
  db_name              = var.database_config.database_name
  db_collation         = var.database_config.collation
  db_charset           = var.database_config.charset

  ip_configuration = {
    ipv4_enabled = false
    # We never set authorized networks, we need all connections via the
    # public IP to be mediated by Cloud SQL.
    authorized_networks = []
    require_ssl         = false
    private_network     = module.vpc.network_self_link
  }

  module_depends_on = [module.private-service-access.peering_completed]
}