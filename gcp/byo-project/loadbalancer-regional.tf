# -------------------------------------
# Regional External Application Load Balancer
# -------------------------------------
# - Regional IP address only (not anycast global)
# - Proxy-only subnet (required for regional EXTERNAL_MANAGED load balancers)

resource "google_compute_subnetwork" "proxy_only" {
  count         = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name          = "${var.prefix}-proxy-only-subnet"
  ip_cidr_range = var.load_balancer_config.proxy_subnet_cidr
  region        = var.region
  project       = var.project_id
  network       = module.vpc.network_id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Regional Network Endpoint Group for Cloud Run
resource "google_compute_region_network_endpoint_group" "regional_neg" {
  count                 = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name                  = "${var.prefix}-regional-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = module.fleet-service.service_name
  }

  depends_on = [module.fleet-service]
}

# IAM binding to allow load balancer to invoke Cloud Run
resource "google_cloud_run_v2_service_iam_member" "regional_lb_invoker" {
  count    = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  project  = var.project_id
  location = module.fleet-service.location
  name     = module.fleet-service.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Regional Backend Service
resource "google_compute_region_backend_service" "regional_backend" {
  count                 = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name                  = "${var.prefix}-regional-backend"
  region                = var.region
  project               = var.project_id
  protocol              = "HTTPS" # Serverless NEG backends use HTTPS regardless of Cloud Run internal config
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group           = google_compute_region_network_endpoint_group.regional_neg[0].id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = local.lb_config.log_sample_rate
  }
}

# Attach security policy via gcloud (workaround for provider limitations)
resource "null_resource" "attach_security_policy" {
  count = local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable ? 1 : 0

  triggers = {
    backend_service_name = google_compute_region_backend_service.regional_backend[0].name
    security_policy_name = google_compute_region_security_policy.regional_security_policy[0].name
    region               = var.region
    project              = var.project_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute backend-services update ${self.triggers.backend_service_name} \
        --region=${self.triggers.region} \
        --project=${self.triggers.project} \
        --security-policy=${self.triggers.security_policy_name}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud compute backend-services update ${self.triggers.backend_service_name} \
        --region=${self.triggers.region} \
        --project=${self.triggers.project} \
        --security-policy="" || true
    EOT
  }

  depends_on = [
    google_compute_region_backend_service.regional_backend,
    google_compute_region_security_policy.regional_security_policy,
    google_compute_region_security_policy_rule.allow_public_paths,
    google_compute_region_security_policy_rule.allow_admin_ips,
    google_compute_region_security_policy_rule.default_deny,
  ]
}

# Regional URL Map
resource "google_compute_region_url_map" "regional_url_map" {
  count           = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name            = "${var.prefix}-regional-url-map"
  region          = var.region
  project         = var.project_id
  default_service = google_compute_region_backend_service.regional_backend[0].id
}

# Regional HTTP Proxy
resource "google_compute_region_target_http_proxy" "regional_main_proxy" {
  count   = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name    = "${var.prefix}-regional-main-proxy"
  region  = var.region
  project = var.project_id
  url_map = google_compute_region_url_map.regional_url_map[0].id
}

# Regional HTTP Forwarding Rule (port 80)
resource "google_compute_forwarding_rule" "regional_main" {
  count                 = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name                  = "${var.prefix}-regional-main-rule"
  region                = var.region
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.regional_main_proxy[0].id
  ip_protocol           = "TCP"
  ip_address            = local.lb_config.create_static_ip ? google_compute_address.regional_ip[0].id : null
  network               = module.vpc.network_self_link

  depends_on = [google_compute_subnetwork.proxy_only]
}

# Regional HTTPS Proxy
resource "google_compute_region_target_https_proxy" "regional_https_proxy" {
  count   = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_managed_cert ? 1 : 0
  name    = "${var.prefix}-regional-url-map-target-proxy"
  region  = var.region
  project = var.project_id
  url_map = google_compute_region_url_map.regional_url_map[0].id
  certificate_manager_certificates = [
    google_certificate_manager_certificate.regional_cert[0].id
  ]
}

# Regional HTTPS Forwarding Rule (port 443)
resource "google_compute_forwarding_rule" "regional_https" {
  count                 = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_managed_cert ? 1 : 0
  name                  = "${var.prefix}-regional-url-map-forwarding-rule"
  region                = var.region
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.regional_https_proxy[0].id
  ip_protocol           = "TCP"
  ip_address            = local.lb_config.create_static_ip ? google_compute_address.regional_ip[0].id : null
  network               = module.vpc.network_self_link

  depends_on = [google_compute_subnetwork.proxy_only]
}

# Static IP address (Regional)
resource "google_compute_address" "regional_ip" {
  count        = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_static_ip ? 1 : 0
  name         = "${var.prefix}-regional-ip"
  region       = var.region
  project      = var.project_id
  address_type = "EXTERNAL"
}

# -------------------------------------
# Certificate Manager (Regional Managed Certificate)
# -------------------------------------

# DNS authorization proves domain ownership to Google Trust Services.
# Required for regional Certificate Manager certs — the LOAD_BALANCER
# provisioning path used by global certs is not available regionally.
resource "google_certificate_manager_dns_authorization" "regional_cert_auth" {
  count    = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_managed_cert ? 1 : 0
  name     = "${var.prefix}-regional-dns-auth"
  location = var.region
  project  = var.project_id
  domain   = trimsuffix(var.dns_record_name, ".")
}

# Managed SSL Certificate
resource "google_certificate_manager_certificate" "regional_cert" {
  count       = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.create_managed_cert ? 1 : 0
  name        = "${var.prefix}-regional-lb"
  location    = var.region
  project     = var.project_id
  description = "Google-managed SSL certificate for regional load balancer"

  managed {
    domains            = [trimsuffix(var.dns_record_name, ".")]
    dns_authorizations = [google_certificate_manager_dns_authorization.regional_cert_auth[0].id]
  }

  lifecycle {
    ignore_changes = [
      labels,
      description
    ]
  }
}
