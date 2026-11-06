locals {
  # Clean the DNS record name for use in managed SSL cert domains (remove trailing dot)
  managed_ssl_domain = trim(var.dns_record_name, ".")

  # The lb-http module names backend services "${name}-backend-${key}".
  # These direct self_links avoid a url_map <-> module dependency cycle when
  # the module is configured to use this custom URL map.
  fleet_backend_self_link      = "https://www.googleapis.com/compute/v1/projects/${var.project_id}/global/backendServices/${var.prefix}-lb-backend-default"
  fleet_bulk_backend_self_link = "https://www.googleapis.com/compute/v1/projects/${var.project_id}/global/backendServices/${var.prefix}-lb-backend-bulk"

  fleet_bulk_paths = [
    "/api/fleet/orbit/software_install/package",
    "/api/latest/fleet/software/*",
    "/api/v1/fleet/software/*",
    "/api/latest/fleet/mdm/apple/installers",
    "/api/latest/fleet/mdm/apple/installers/*",
    "/api/v1/fleet/mdm/apple/installers",
    "/api/v1/fleet/mdm/apple/installers/*",
  ]
}

# Create/Manage the DNS Zone in Cloud DNS
resource "google_dns_managed_zone" "fleet_dns_zone" {
  project  = var.project_id
  name     = "${var.prefix}-zone"
  dns_name = var.dns_zone_name
}

resource "google_compute_url_map" "fleet" {
  project         = var.project_id
  name            = "${var.prefix}-lb-routing"
  default_service = local.fleet_backend_self_link

  lifecycle {
    create_before_destroy = true
  }

  host_rule {
    hosts        = ["*"]
    path_matcher = "default"
  }

  path_matcher {
    name            = "default"
    default_service = local.fleet_backend_self_link

    path_rule {
      paths   = local.fleet_bulk_paths
      service = local.fleet_bulk_backend_self_link
    }
  }
}

# Configure the External HTTP(S) Load Balancer
module "fleet_lb" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "${var.prefix}-lb" # e.g., fleet-lb

  # SSL Configuration
  ssl                             = true
  https_redirect                  = true # Enforce HTTPS
  managed_ssl_certificate_domains = [local.managed_ssl_domain]
  create_url_map                  = false
  url_map                         = google_compute_url_map.fleet.self_link

  # Backend Configuration
  backends = {
    default = {
      description = "Backend for Fleet Cloud Run service"
      enable_cdn  = false # Set to true if you want Cloud CDN
      protocol    = "HTTP"
      groups = [
        {
          group = google_compute_region_network_endpoint_group.neg.id
        }
      ]

      log_config = {
        enable      = true
        sample_rate = 1.0 # Log all requests
      }

      # IAP (Identity-Aware Proxy) - disabled by default
      iap_config = {
        enable = false
      }
    }

    bulk = {
      description = "h2c backend for large Fleet software installer transfers"
      enable_cdn  = false
      protocol    = "HTTP"
      groups = [
        {
          group = google_compute_region_network_endpoint_group.bulk_neg.id
        }
      ]

      log_config = {
        enable      = true
        sample_rate = 1.0 # Log all requests
      }

      # IAP (Identity-Aware Proxy) - disabled by default
      iap_config = {
        enable = false
      }
    }
  }

  depends_on = [
    google_compute_region_network_endpoint_group.neg,
    google_compute_region_network_endpoint_group.bulk_neg,
  ]
}

# Create the DNS A Record for the Load Balancer
resource "google_dns_record_set" "fleet_dns_record" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.fleet_dns_zone.name
  name         = var.dns_record_name
  type         = "A"
  ttl          = 300 # Time-to-live in seconds

  # Point to the external IP address of the created load balancer
  rrdatas = [module.fleet_lb.external_ip]

  depends_on = [module.fleet_lb]
}
