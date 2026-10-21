resource "google_certificate_manager_trust_config" "this" {
  project     = var.project_id
  name        = "${var.customer_prefix}-okta-trust-config"
  description = "Fleet SCEP CA trust config for Okta conditional access mTLS"
  location    = "global"

  trust_stores {
    trust_anchors {
      pem_certificate = file(var.ca_certificate_pem_file)
    }
  }
}

resource "google_network_security_server_tls_policy" "this" {
  project     = var.project_id
  name        = "${var.customer_prefix}-okta-mtls-policy"
  description = "mTLS policy for Fleet Okta conditional access — rejects connections without a valid client cert"
  location    = "global"

  mtls_policy {
    client_validation_mode         = "REJECT_INVALID"
    client_validation_trust_config = google_certificate_manager_trust_config.this.id
  }

  lifecycle {
    # GCP sometimes returns the project number instead of the project ID in this
    # field, causing spurious replace plans. The trust config itself is immutable
    # so ignoring drift here is safe.
    ignore_changes = [mtls_policy[0].client_validation_trust_config]
  }
}
