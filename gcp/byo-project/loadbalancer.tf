# Configure the External HTTP(S) Load Balancer
module "fleet_lb" {
  count   = local.lb_config.enable && !local.lb_config.use_regional_lb ? 1 : 0
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "${var.prefix}-lb"

  ssl                             = true
  https_redirect                  = local.lb_config.https_redirect
  managed_ssl_certificate_domains = local.lb_config.create_managed_cert ? [local.managed_ssl_domain] : []

  backends = {
    default = {
      description = "Backend for Fleet Cloud Run service"
      enable_cdn  = false
      protocol    = "HTTP"
      groups = [
        {
          group = google_compute_region_network_endpoint_group.neg.id
        }
      ]

      log_config = {
        enable      = true
        sample_rate = local.lb_config.log_sample_rate
      }

      iap_config = {
        enable = false
      }
    }
  }

  depends_on = [google_compute_region_network_endpoint_group.neg]
}
