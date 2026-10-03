output "server_tls_policy" {
  description = "Self-link of the ServerTLSPolicy. Pass to the fleet_lb module as server_tls_policy."
  value       = google_network_security_server_tls_policy.this.id
}

output "client_cert_header" {
  description = "Custom request header string that forwards the client certificate serial number to Fleet. Add to backends.default.custom_request_headers in the fleet_lb module."
  value       = "X-Client-Cert-Serial: {client_cert_serial_number}"
}

output "redirect_rules" {
  description = "Path matcher rules to add to the Fleet LB URL map, redirecting the Okta SSO path to the mTLS subdomain. Note: this uses GCP URL map path matcher shape, which differs from the AWS addon's ALB listener rule shape."
  value = [{
    paths = ["/api/fleet/conditional_access/idp/sso"]
    url_redirect = {
      https_redirect = true
      host_redirect  = "${var.subdomain_prefix}.${var.fleet_domain}"
      path_redirect  = "/api/fleet/conditional_access/idp/sso"
      strip_query    = false
    }
  }]
}

output "trust_config_id" {
  description = "The fully-qualified resource ID of the google_certificate_manager_trust_config (projects/{project}/locations/global/trustConfigs/{name})."
  value       = google_certificate_manager_trust_config.this.id
}
