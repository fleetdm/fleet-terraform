variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "customer_prefix" {
  description = "Prefix used for resource names"
  type        = string
  default     = "fleet"
}

variable "ca_certificate_pem_file" {
  description = "Path to the Fleet SCEP CA certificate in PEM format. Must be relative to the root module directory (where terraform apply is run) or an absolute path. Obtain with: curl 'https://<fleet-domain>/api/fleet/conditional_access/scep?operation=GetCACert' --output cacert.tmp && openssl x509 -inform der -in cacert.tmp -out ca.pem && rm cacert.tmp"
  type        = string
}

variable "subdomain_prefix" {
  description = "Subdomain prefix for the mTLS endpoint (e.g. 'okta' produces okta.<fleet_domain>)"
  type        = string
  default     = "okta"
}

variable "fleet_domain" {
  description = "The base Fleet domain, e.g. 'fleet.campusgroup.co'. Used to construct the mTLS redirect target."
  type        = string
}
