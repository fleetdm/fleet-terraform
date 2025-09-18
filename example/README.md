# Fleet Terraform Module Example
This code provides some example usage of the Fleet Terraform module, including how some addons can be used to extend functionality.  Prior to applying, edit the locals in `main.tf` to match the settings you want for your Fleet instance including:

 - domain name
 - route53 zone name (may match the domain name)
 - license key (if premium)
 - uncommenting the mdm module if mdm is desired
 - any extra settings to be passed to Fleet via ENV var.

To deploy:
1. `terraform apply`

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 6.11.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.11.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_acm"></a> [acm](#module\_acm) | terraform-aws-modules/acm/aws | 4.3.1 |
| <a name="module_fleet"></a> [fleet](#module\_fleet) | github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.18.0 | n/a |
| <a name="module_migrations"></a> [migrations](#module\_migrations) | github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.1.0 | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_route53_record.main](https://registry.terraform.io/providers/hashicorp/aws/6.11.0/docs/resources/route53_record) | resource |
| [aws_route53_zone.main](https://registry.terraform.io/providers/hashicorp/aws/6.11.0/docs/resources/route53_zone) | resource |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_route53_name_servers"></a> [route53\_name\_servers](#output\_route53\_name\_servers) | Ensure that these records are added to the parent DNS zone Delete this output if you switched the route53 zone above to a data source. |
