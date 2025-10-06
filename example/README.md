# Fleet Terraform Module Example
This code provides some example usage of the Fleet Terraform module, including how some addons can be used to extend functionality.  Prior to applying, edit the locals in `main.tf` to match the settings you want for your Fleet instance including:

 - domain name
 - route53 zone name (may match the domain name)
 - license key (if premium)
 - any extra settings to be passed to Fleet via ENV var.

To deploy:

1. `terraform apply`

If using a new route53 zone:

- From the output, obtain the NS records created for the zone and add them to the parent DNS zone

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 6.11.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.11.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.7.2 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | 4.1.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_acm"></a> [acm](#module\_acm) | terraform-aws-modules/acm/aws | 4.3.1 |
| <a name="module_fleet"></a> [fleet](#module\_fleet) | github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.18.2 | n/a |
| <a name="module_mdm"></a> [mdm](#module\_mdm) | github.com/fleetdm/fleet-terraform/addons/mdm?depth=1&ref=tf-mod-addon-mdm-v2.0.0 | n/a |
| <a name="module_migrations"></a> [migrations](#module\_migrations) | github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.1.0 | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_route53_record.main](https://registry.terraform.io/providers/hashicorp/aws/6.11.0/docs/resources/route53_record) | resource |
| [aws_route53_zone.main](https://registry.terraform.io/providers/hashicorp/aws/6.11.0/docs/resources/route53_zone) | resource |
| [aws_secretsmanager_secret_version.scep](https://registry.terraform.io/providers/hashicorp/aws/6.11.0/docs/resources/secretsmanager_secret_version) | resource |
| [random_password.challenge](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [tls_private_key.scep_key](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.scep_cert](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_route53_name_servers"></a> [route53\_name\_servers](#output\_route53\_name\_servers) | Ensure that these records are added to the parent DNS zone Delete this output if you switched the route53 zone above to a data source. |
