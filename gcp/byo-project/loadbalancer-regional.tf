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

# The load balancer's run.invoker/allUsers binding is owned solely by the
# unconditional google_cloud_run_v2_service_iam_member.allow_lb_invoker in
# cloud_run.tf. An earlier draft of this file declared an identical
# regional_lb_invoker member; because both resources manage the same
# (role, member) pair, destroying the duplicate would revoke the shared
# binding. Forget it from state instead so no remote IAM change occurs.
removed {
  from = google_cloud_run_v2_service_iam_member.regional_lb_invoker

  lifecycle {
    destroy = false
  }
}

# Regional Backend Service
#
# Uses google-beta because security_policy on google_compute_region_backend_service
# is only exposed by the beta provider (hashicorp/google 6.x lacks it). Moving
# this existing resource from google to google-beta does not replace it: both
# providers share the resource type, schema and ID format, so Terraform just
# records the new provider address on the next apply.
resource "google_compute_region_backend_service" "regional_backend" {
  provider = google-beta

  count                 = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name                  = "${var.prefix}-regional-backend"
  region                = var.region
  project               = var.project_id
  protocol              = "HTTPS" # Serverless NEG backends use HTTPS regardless of Cloud Run internal config
  load_balancing_scheme = "EXTERNAL_MANAGED"

  # Cloud Armor attachment (regional LB only, off by default). The field is
  # Optional (not Computed), so null keeps no policy attached and, when
  # cloud_armor.enable is turned off, detaches a previously attached policy
  # before the policy itself is destroyed (ordering enforced by
  # terraform_data.cloud_armor_detach_before_destroy below). Terraform also
  # detects any out-of-band attachment drift.
  security_policy = var.cloud_armor.enable ? google_compute_region_security_policy.regional_security_policy[0].id : null

  backend {
    group           = google_compute_region_network_endpoint_group.regional_neg[0].id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = local.lb_config.log_sample_rate
  }

  # Attach only once the policy is fully configured: the allow rules exist and
  # the implicit default rule has been patched to deny(403). The rules do not
  # reference the backend service, so this adds no dependency cycle.
  depends_on = [
    google_compute_region_security_policy_rule.allow_public_paths,
    google_compute_region_security_policy_rule.allow_admin_ips,
    google_compute_region_security_policy_rule.default_deny,
  ]
}

# Detach-before-delete ordering for the Cloud Armor policy.
#
# When cloud_armor.enable goes from true to false, the backend service is
# updated (security_policy -> null) while the policy and its rules are
# destroyed. By default Terraform destroys a dependency *before* updating the
# resource that used it, which would strip the rules from, and then try to
# delete, a policy that is still attached (GCP rejects deleting it).
# A create_before_destroy resource forces create_before_destroy onto everything
# it depends on, so depending on the policy and its rules makes Terraform
# detach the backend first, then delete the rules, then the policy: the same
# order as the old gcloud destroy provisioner. A renamed policy (new name from
# var.prefix) is likewise swapped in before the old one is deleted; rule
# priorities are fixed per key, so replacement never collides.
#
# Terraform takes this setting for a pure destroy from the state written when
# the policy was last planned with Cloud Armor enabled. A policy created by the
# earlier gcloud-based draft has no such state, so that deployment must be
# upgraded once with cloud_armor unchanged before disabling it.
resource "terraform_data" "cloud_armor_detach_before_destroy" {
  count = local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable ? 1 : 0
  input = google_compute_region_security_policy.regional_security_policy[0].id

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_compute_region_security_policy_rule.allow_public_paths,
    google_compute_region_security_policy_rule.allow_admin_ips,
    google_compute_region_security_policy_rule.default_deny,
  ]
}

# An earlier draft attached the Cloud Armor policy with a null_resource running
# gcloud local-exec. Attachment is now the native security_policy argument
# above. Forget the old resource from state instead of destroying it: its
# destroy-time provisioner would run gcloud and detach the policy that the
# backend service now manages natively.
removed {
  from = null_resource.attach_security_policy

  lifecycle {
    destroy = false
  }
}

# Regional URL Map
resource "google_compute_region_url_map" "regional_url_map" {
  count           = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name            = "${var.prefix}-regional-url-map"
  region          = var.region
  project         = var.project_id
  default_service = google_compute_region_backend_service.regional_backend[0].id
}

# Regional HTTP -> HTTPS redirect URL Map (mirrors the global lb-http module's
# https_redirect behaviour: 301 to HTTPS, query string preserved).
resource "google_compute_region_url_map" "regional_https_redirect" {
  count   = local.lb_config.enable && local.lb_config.use_regional_lb && local.lb_config.https_redirect ? 1 : 0
  name    = "${var.prefix}-regional-https-redirect"
  region  = var.region
  project = var.project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# Regional HTTP Proxy (port 80). Redirects to HTTPS when https_redirect is
# true; otherwise serves the backend over plain HTTP.
resource "google_compute_region_target_http_proxy" "regional_main_proxy" {
  count   = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
  name    = "${var.prefix}-regional-main-proxy"
  region  = var.region
  project = var.project_id
  url_map = (
    local.lb_config.https_redirect ?
    google_compute_region_url_map.regional_https_redirect[0].id :
    google_compute_region_url_map.regional_url_map[0].id
  )
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
  ip_address            = google_compute_address.regional_ip[0].address
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
  ip_address            = google_compute_address.regional_ip[0].address
  network               = module.vpc.network_self_link

  depends_on = [google_compute_subnetwork.proxy_only]
}

# Static IP address (Regional)
# Always reserved for the regional LB, independent of create_static_ip.
# Regional forwarding rules without an explicit address each receive their own
# ephemeral IP, so ports 80 and 443 would land on different IPs while the DNS
# A record (and load_balancer_ip_address output) can only point at one of
# them. Sharing a single reserved address keeps HTTP, HTTPS and DNS aligned.
resource "google_compute_address" "regional_ip" {
  count        = local.lb_config.enable && local.lb_config.use_regional_lb ? 1 : 0
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
