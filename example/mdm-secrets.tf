resource "tls_private_key" "scep_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "scep_cert" {
  private_key_pem = tls_private_key.scep_key.private_key_pem

  subject {
    common_name  = "Fleet Root CA"
    organization = "Fleet."
    country      = "US"
  }

  is_ca_certificate     = true
  validity_period_hours = 87648

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "random_password" "challenge" {
  length  = 12
  special = false
}

resource "aws_secretsmanager_secret_version" "scep" {
  secret_id = module.mdm.scep.id
  secret_string = jsonencode(
    {
      FLEET_MDM_APPLE_SCEP_CERT_BYTES = tls_self_signed_cert.scep_cert.cert_pem
      FLEET_MDM_APPLE_SCEP_KEY_BYTES  = tls_private_key.scep_key.private_key_pem
      FLEET_MDM_APPLE_SCEP_CHALLENGE  = random_password.challenge.result
    }
  )
}