# Fleet Terraform Module Example
This code provides some example usage of the Fleet Terraform module, including how some addons can be used to extend functionality.  Prior to applying, edit the locals in `main.tf` to match the settings you want for your Fleet instance including:

 - domain name
 - route53 zone name (may match the domain name)
 - license key (if premium)
 - uncommenting the mdm module if mdm is desired
 - any extra settings to be passed to Fleet via ENV var.

Due to Terraform issues, this code requires 3 applies "from scratch":
1. `terraform apply -target module.fleet.module.vpc`
2. `terraform apply -target module.osquery-carve -target module.firehose-logging`
3. If using a new route53 zone:
  - `terraform apply -target aws_route53_zone.main`
  - From the output, obtain the NS records created for the zone and add them to the parent DNS zone
4. If enabling mdm: `terraform apply -target module.mdm`.  It will need to be uncommented as well as the KMS section below it.
5. `terraform apply -target module.fleet`
6. `terraform apply`
7. If enabling mdm do the following:
 - Record the KMS key from step 5 output.
 - Create the Windows MDM cert via the document at https://fleetdm.com/guides/windows-mdm-setup#step-1-generate-your-certificate-and-key, but name them as scep.key and scep.crt to follow a legacy convention of the mdm module.
 - Place the certificates in the `resources` folder with the following names based upon their function:
```
scep.crt
scep.key
```
 - Using the `encrypt.sh` script, KMS encrypt all of these secrets as follows:
```
cd resources
for i in *; do ../scripts/encrypt.sh <kms-key-id-from-terraform-output> $i $i.encrypted; done
for i in *.encrypted; do rm ${i/.encrypted/}; done
```
This will encrypt all of the mdm secrets and add the .encrypted extension to them. It will also remove the non-encrypted version of the secrets so that they are encrypted at rest even locally.

 - Uncomment all of the resources and data sources in `mdm-secrets.tf`.
 - Re-run `terraform apply` to populate the Secrets Manager secrets.
 - Uncomment the sections in the `fleet_config` portion of `main.tf` for mdm and run a final `terraform apply`.  Services will restart with mdm enabled.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 5.36.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.36.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_acm"></a> [acm](#module\_acm) | terraform-aws-modules/acm/aws | 4.3.1 |
| <a name="module_fleet"></a> [fleet](#module\_fleet) | github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.14.0 | n/a |
| <a name="module_migrations"></a> [migrations](#module\_migrations) | github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.0.1 | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_route53_record.main](https://registry.terraform.io/providers/hashicorp/aws/5.36.0/docs/resources/route53_record) | resource |
| [aws_route53_zone.main](https://registry.terraform.io/providers/hashicorp/aws/5.36.0/docs/resources/route53_zone) | resource |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_route53_name_servers"></a> [route53\_name\_servers](#output\_route53\_name\_servers) | Ensure that these records are added to the parent DNS zone Delete this output if you switched the route53 zone above to a data source. |
