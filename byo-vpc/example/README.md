## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.8 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.88.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.6.3 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_acm"></a> [acm](#module\_acm) | terraform-aws-modules/acm/aws | 4.3.1 |
| <a name="module_byo-vpc"></a> [byo-vpc](#module\_byo-vpc) | github.com/fleetdm/fleet-terraform//byo-vpc | tf-mod-byo-vpc-v1.13.0 |
| <a name="module_firehose-logging"></a> [firehose-logging](#module\_firehose-logging) | github.com/fleetdm/fleet-terraform//addons/logging-destination-firehose | tf-mod-addon-logging-destination-firehose-v1.1.1 |
| <a name="module_migrations"></a> [migrations](#module\_migrations) | github.com/fleetdm/fleet-terraform//addons/migrations | tf-mod-addon-migrations-v2.0.1 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 5.1.2 |

## Resources

| Name | Type |
|------|------|
| [aws_route53_record.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [random_pet.main](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [aws_route53_zone.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

## Inputs

No inputs.

## Outputs

No outputs.
