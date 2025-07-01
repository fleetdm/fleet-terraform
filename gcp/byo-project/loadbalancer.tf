locals {
  # Clean the DNS record name for use in managed SSL cert domains (remove trailing dot)
  managed_ssl_domain = trim(var.dns_record_name, ".")
}

# Create/Manage the DNS Zone in Cloud DNS
resource "google_dns_managed_zone" "fleet_dns_zone" {
  project  = var.project_id
  name     = "${var.prefix}-zone"
  dns_name = var.dns_zone_name
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

  # Backend Configuration
  backends = {
    default = {
      description             = "Backend for Fleet Cloud Run service"
      enable_cdn              = false # Set to true if you want Cloud CDN
      protocol                = "HTTP"
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
  }

  depends_on = [google_compute_region_network_endpoint_group.neg]
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