locals {
  # Clean the DNS record name for use in managed SSL cert domains (remove trailing dot)
  managed_ssl_domain = trim(var.dns_record_name, ".")
  lb_config          = var.load_balancer_config
  dns_config         = var.dns_config
}

# -------------------------------------
# DNS Management (Cloud DNS)
# -------------------------------------
# Set dns_config.enable = false when using external DNS providers

resource "google_dns_managed_zone" "fleet_dns_zone" {
  count    = local.dns_config.enable ? 1 : 0
  project  = var.project_id
  name     = "${var.prefix}-zone"
  dns_name = var.dns_zone_name
}

resource "google_dns_record_set" "fleet_dns_record" {
  count        = local.dns_config.enable && local.lb_config.enable ? 1 : 0
  project      = var.project_id
  managed_zone = google_dns_managed_zone.fleet_dns_zone[0].name
  name         = var.dns_record_name
  type         = "A"
  ttl          = 300

  # Point to LB IP (regional or global)
  rrdatas = [
    local.lb_config.use_regional_lb ?
    google_compute_forwarding_rule.regional_main[0].ip_address :
    module.fleet_lb[0].external_ip
  ]
}

# CNAME record required by the regional cert's DNS authorization.
# Only published automatically when using Cloud DNS; for external DNS,
# see the `regional_cert_dns_authorization_record` output and create
# the CNAME at your DNS provider manually.
resource "google_dns_record_set" "regional_cert_auth_cname" {
  count = local.dns_config.enable && local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_managed_cert ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.fleet_dns_zone[0].name
  name         = google_certificate_manager_dns_authorization.regional_cert_auth[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.regional_cert_auth[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.regional_cert_auth[0].dns_resource_record[0].data]
}
