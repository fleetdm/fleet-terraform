# GCP Okta Conditional Access

Enables Fleet's [Okta conditional access](https://fleetdm.com/guides/okta-conditional-access-integration) on GCP using the Application Load Balancer's native mTLS support. When a device authenticates through Okta, the LB validates its certificate against the Fleet SCEP CA and forwards the serial number to Fleet via the `X-Client-Cert-Serial` header.

GCP's `ServerTLSPolicy` applies at the HTTPS proxy level, so this addon provisions a **dedicated second proxy and global IP** for the `okta.<fleet_domain>` subdomain — leaving the main Fleet UI proxy untouched and mTLS-free. No separate load balancer is needed (contrast with the AWS addon).

## Requirements

- Fleet deployment using `gcp/byo-project` (or equivalent with `GoogleCloudPlatform/lb-http/google//modules/serverless_negs`)
- A valid Fleet instance reachable to obtain the CA certificate
- The CA certificate in PEM format stored at `resources/conditional-ca.pem` in your Terraform directory

## Architecture

```text
fleet.example.com  →  1.2.3.4  →  fleet-lb-https-proxy       (no mTLS)       →  Cloud Run
okta.fleet.example.com  →  5.6.7.8  →  fleet-okta-https-proxy  (mTLS enforced)  →  Cloud Run
                                                  ↑
                                       ServerTLSPolicy (REJECT_INVALID)
                                       TrustConfig (Fleet SCEP CA)
```

Both proxies share the same URL map and backend service. The mTLS proxy adds the `X-Client-Cert-Serial` header before forwarding to the backend.

## Differences from AWS Addon

| Concern | AWS | GCP |
| --- | --- | --- |
| CA cert storage | S3 bucket | Inline in `TrustConfig` (no object storage needed) |
| mTLS termination | Separate ALB | Dedicated proxy on existing LB |
| Cert revocation | Supported | **Not supported** by GCP LB — see note below |
| Serial header | ALB-native header | Custom request header `{client_cert_serial_number}` |
| Extra infrastructure cost | Second ALB + global IP | Second global IP only |

> **Revocation note:** GCP Application Load Balancers do not perform certificate revocation checking. Revoked certs with otherwise-valid chains will pass mTLS validation at the LB. Fleet itself checks the serial against its device records, so devices with revoked certs will still be blocked by Fleet — but the LB will not drop the connection at the TLS handshake.

## Obtaining the CA Certificate

Run these commands from your Terraform directory:

```sh
mkdir -p resources
curl 'https://<your-fleet-domain>/api/fleet/conditional_access/scep?operation=GetCACert' --output cacert.tmp
openssl x509 -inform der -in cacert.tmp -out resources/conditional-ca.pem
rm cacert.tmp
```

## Usage

```hcl
module "okta_conditional_access" {
  source = "github.com/fleetdm/fleet-terraform//addons/gcp/okta-conditional-access?depth=1&ref=tf-mod-addon-gcp-okta-conditional-access-v0.1.0"

  project_id              = var.project_id
  ca_certificate_pem_file = "${path.module}/resources/conditional-ca.pem"
  fleet_domain            = "fleet.example.com"
}

module "fleet" {
  source = "github.com/fleetdm/fleet-terraform//gcp/byo-project?depth=1&ref=..."

  # ... your existing fleet config ...

  # Wire in the mTLS policy, cert-serial header, and okta subdomain:
  server_tls_policy              = module.okta_conditional_access.server_tls_policy
  backend_custom_request_headers = [module.okta_conditional_access.client_cert_header]
  okta_subdomain                 = "okta.fleet.example.com"
}
```

Setting `okta_subdomain` on the `fleet` module causes `gcp/byo-project` to:

1. Provision a dedicated global IP (`fleet-okta-ip`)
2. Create a managed SSL cert for `okta.<fleet_domain>` only (`fleet-okta-cert`)
3. Create a second HTTPS proxy with the `ServerTLSPolicy` attached (`fleet-okta-https-proxy`)
4. Create a forwarding rule on the new IP → okta proxy
5. Add a URL map host rule redirecting `/api/fleet/conditional_access/idp/sso` to the okta subdomain
6. Create a DNS A record for `okta.<fleet_domain>` pointing to the new IP

## First-time Deployment Notes

When applying this addon to an existing Fleet deployment, Terraform must replace the main managed SSL certificate (it is recreated without the okta domain, which is now on its own cert). The existing certificate cannot be deleted while attached to the HTTPS proxy, causing a 409 conflict. Run these steps before `terraform apply`:

```sh
# 1. Create a temporary cert for the main domain
gcloud compute ssl-certificates create fleet-lb-cert-new \
  --domains=<fleet-domain> \
  --project=<project-id> \
  --global

# 2. Swap the main proxy to the temp cert
gcloud compute target-https-proxies update fleet-lb-https-proxy \
  --ssl-certificates=fleet-lb-cert-new \
  --project=<project-id> \
  --global

# 3. Remove the mTLS policy from the main proxy (if previously applied)
gcloud compute target-https-proxies update fleet-lb-https-proxy \
  --project=<project-id> \
  --global \
  --clear-server-tls-policy

# 4. Delete the old cert (now detached)
gcloud compute ssl-certificates delete fleet-lb-cert \
  --project=<project-id> --global --quiet

# 5. Remove stale resources from state
terraform state rm 'module.fleet.module.fleet_lb.google_compute_managed_ssl_certificate.default[0]'
terraform state rm 'module.fleet.module.fleet_lb.google_compute_url_map.default[0]'  # if present

# 6. Apply
terraform apply

# 7. Clean up the temporary cert
gcloud compute ssl-certificates delete fleet-lb-cert-new \
  --project=<project-id> --global --quiet
```

This is a one-time migration step. Future `terraform apply` runs will not require it.

## Provider Requirements

| Name | Version |
| --- | --- |
| terraform | ~> 1.11 |
| google | >= 6.35.0 |

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `project_id` | GCP project ID | `string` | — | yes |
| `customer_prefix` | Resource name prefix | `string` | `"fleet"` | no |
| `ca_certificate_pem_file` | Path to Fleet SCEP CA cert (PEM) | `string` | — | yes |
| `subdomain_prefix` | Subdomain prefix for the mTLS endpoint | `string` | `"okta"` | no |
| `fleet_domain` | Base Fleet domain e.g. `fleet.example.com` | `string` | — | yes |

## Outputs

| Name | Description |
| --- | --- |
| `server_tls_policy` | Self-link of the ServerTLSPolicy — pass to `server_tls_policy` on the fleet module |
| `client_cert_header` | Custom request header string — add to `backend_custom_request_headers` |
| `redirect_rules` | URL map path rules for the Okta SSO redirect |
| `trust_config_id` | The fully-qualified resource ID of the `google_certificate_manager_trust_config` |
