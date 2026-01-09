# Okta conditoinal access

Since mTLS is used for conditional access with Okta, we need to move the connection request to a separate subdomain that requires mTLS and uses the CA stored in Fleet and the certificate issued to the device seeking access.

This module helps automate that for a terraform deployment.  By default the module assumes that okta is added as a subdomain to the Fleet primary domain (e.g. fleet.example.com leverages okta.fleet.example.com), but this can be customized.

A separate load balancer is created to handle the mTLS authorization.  The module only handles basic certificate validation and passes the certificate serial on to Fleet via a header in order to handle the final authorization or revocation step.

## Requirements

- A separate subdomain for conditional access
- A valid TLS certificate issued for the domain name
- HTTPS listener rules applied to the main Fleet load balancer to handle redirects (generated as an output of this module)
- The load balancer configured by this module applied as an extra load balancer to the fleet\_config on the primary Fleet in terraform
- The CA certificate in PEM format stored at "resources/conditional-ca.pem"

## Obtaining the CA certificate

Run these commands while in your Fleet terraform directory/checkout.

```sh
mkdir -p resources
# Replace with your domain name. This is the public cert and doesn't need special protection.
curl 'https://fleet.example.com/api/fleet/conditional_access/scep?operation=GetCACert' --output cacert.tmp
openssl x509 -inform der -in cacert.tmp -out resources/conditional-ca.pem
rm cacert.tmp
```

## Configuration Example

```hcl
locals {
  domain_name = "fleet.example.com"
  okta_subdomain = "okta.${local.domain_name}"
}

module "okta_acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "4.3.1"

  domain_name = local.okta_subdomain
  # Assumes you are managing your domain in route53 inside of this config.
  zone_id = aws_route53_zone.main.id

  wait_for_validation = true
}

resource "aws_route53_record" "okta" {
  # If you change the route53_zone to a data source this also needs to become "data.aws_route53_zone.main.id"
  zone_id = aws_route53_zone.main.id
  name    = local.okta_subdomain
  type    = "A"

  alias {
    name                   = module.okta-conditional-access.alb.lb_dns_name
    zone_id                = module.okta-conditional-access.alb.lb_zone_id
    evaluate_target_health = true
  }
}

module "fleet" {
  source          = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.19.0"
  ...
  fleet_config = {
    ...
    # Required to allow the ALB to talk to the ECS containers.
    networking = {
      ingress_sources = {
        security_groups = [module.okta-conditional-access.alb.security_group_id]
      }
    }
    extra_load_balancers = [{
      target_group_arn = module.okta-conditional-access.alb.target_groups["tg-0"].arn
      container_name   = "fleet"
      container_port   = 8080
    }]
  }
  ...
  alb_config = {
    ...
    # If you have existing rules, use concat() to combine these with them.
    # Note: by default the rules use the highest priority indexes starting at 1,
    # but that can be configured inside the module.
    https_listener_rules = module.okta-conditional-access.redirect_rules
  }
}

module "okta-conditional-access" {
  source = "github.com/fleetdm/fleet-terraform/addons/okta-conditional-access?depth=1&ref=tf-mod-addon-okta-conditional-access-v0.5.0"
  customer_prefix = "fleet"
  vpc_id = module.fleet.vpc.vpc_id
  trust_store_s3_config = {
    bucket_prefix = "fleet-okta-trust-store"
  }
  alb_config = {
    name = "fleet-okta"
    # If using the ALB logging module:
    access_logs = {
      bucket  = module.logging_alb.log_s3_bucket_id
      prefix  = "fleet"
      enabled = true
    }
    subnets = module.fleet.vpc.public_subnets
    certificate_arn = module.okta_acm.acm_certificate_arn
    idle_timeout = 60
    trust_store = {
      ca_certificates_bundle_s3_key            = "ca.pem"
      ca_certificates_bundle_s3_object_version = null
      ca_certificates_bundle_file              = "${path.module}/resources/conditional-ca.pem"
      create_trust_store_revocation            = false
      trust_store_revocation_lists             = {}
    }
  }
}
```

## Final comments

Once this is configured, when you attempt to leverage the conditional access, you will be prompted to use the certificate that is installed on your system if it already there during the authoriation redriect.  If the certificate is not installed, the load balancer will immediately terminate the connection during the handshake and you will get a connection resset error message.

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.28.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_lb_trust_store_bucket"></a> [lb\_trust\_store\_bucket](#module\_lb\_trust\_store\_bucket) | terraform-aws-modules/s3-bucket/aws | 5.9.1 |
| <a name="module_okta_mtls_alb"></a> [okta\_mtls\_alb](#module\_okta\_mtls\_alb) | terraform-aws-modules/alb/aws | 10.4.0 |

## Resources

| Name | Type |
|------|------|
| [aws_lb_trust_store.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_trust_store) | resource |
| [aws_lb_trust_store_revocation.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_trust_store_revocation) | resource |
| [aws_s3_object.trust_store_ca](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_security_group.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.alb_trust_store_restricted](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alb_config"></a> [alb\_config](#input\_alb\_config) | n/a | <pre>object({<br/>    name                       = optional(string, "fleet-okta")<br/>    subnets                    = list(string)<br/>    security_groups            = optional(list(string), [])<br/>    access_logs                = optional(map(string), {})<br/>    certificate_arn            = string<br/>    allowed_cidrs              = optional(list(string), ["0.0.0.0/0"])<br/>    allowed_ipv6_cidrs         = optional(list(string), ["::/0"])<br/>    egress_cidrs               = optional(list(string), ["0.0.0.0/0"])<br/>    egress_ipv6_cidrs          = optional(list(string), ["::/0"])<br/>    extra_target_groups        = optional(any, [])<br/>    https_listener_rules       = optional(any, [])<br/>    https_overrides            = optional(any, {})<br/>    xff_header_processing_mode = optional(string, null)<br/>    tls_policy                 = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")<br/>    idle_timeout               = optional(number, 60)<br/>    internal                   = optional(bool, false)<br/>    enable_deletion_protection = optional(bool, false)<br/>    subdomain_prefix           = optional(string, "okta")<br/>    trust_store = optional(any, {<br/>      ca_certificates_bundle_s3_key            = "ca.pem"<br/>      ca_certificates_bundle_s3_object_version = null<br/>      ca_certificates_bundle_file              = null<br/>      create_trust_store_revocation            = false<br/>      trust_store_revocation_lists             = {}<br/>    })<br/>  })</pre> | n/a | yes |
| <a name="input_customer_prefix"></a> [customer\_prefix](#input\_customer\_prefix) | n/a | `string` | `"fleet"` | no |
| <a name="input_redirect_priority"></a> [redirect\_priority](#input\_redirect\_priority) | The priority of the redirect https\_listener\_rule generated in the output | `number` | `1` | no |
| <a name="input_trust_store_s3_config"></a> [trust\_store\_s3\_config](#input\_trust\_store\_s3\_config) | n/a | <pre>object({<br/>    bucket_prefix                      = optional(string, "fleet-okta-trust-store")<br/>    newer_noncurrent_versions          = optional(number, 5)<br/>    noncurrent_version_expiration_days = optional(number, 30)<br/>  })</pre> | <pre>{<br/>  "bucket_prefix": "fleet-okta-trust-store",<br/>  "newer_noncurrent_versions": 5,<br/>  "noncurrent_version_expiration_days": 30<br/>}</pre> | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | n/a | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alb"></a> [alb](#output\_alb) | n/a |
| <a name="output_alb_security_group"></a> [alb\_security\_group](#output\_alb\_security\_group) | n/a |
| <a name="output_lb_trust_store__bucket"></a> [lb\_trust\_store\_\_bucket](#output\_lb\_trust\_store\_\_bucket) | n/a |
| <a name="output_redirect_rules"></a> [redirect\_rules](#output\_redirect\_rules) | n/a |
