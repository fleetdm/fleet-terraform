# Cloudfront Software Installers

This module allows for Fleet software installers to be served via AWS Cloudfront instead of directly from Fleet.

This should improve the performance of software installer delivery.  For general information about Fleet and Cloudfront see the following:

https://fleetdm.com/guides/cdn-signed-urls
https://victoronsoftware.com/posts/cloudfront-signed-urls/

The second link includes a script that can be used to test and see if signed URLs are working outside of Fleet for troubleshooting purposes.

## Other module requirements

These are the minimum versions of modules required if used:

 - tf-mod-root-v1.13.0
 - tf-mod-byo-vpc-v1.14.0
 - tf-mod-byo-db-v1.10.0
 - tf-mod-byo-ecs-v1.9.0
 - tf-mod-addon-logging-alb-v1.3.0

Previous versions do not allow for proper interaction with both the software installers and logging s3 buckets.

## Configuration considerations for other modules

### tf-mod-root/tf-mod-byo-vpc/tf-mod-byo-db/tf-mod-byo-ecs

For any of these modules, the software installers configuration will require a KMS key created in order to be able to set a key policy.

This is the relevant configuration starting at the software installers configuration block:

```
    software_installers = {
      bucket_prefix  = "fleet-software-installers-"
      create_kms_key = true
      kms_alias      = "fleet-software-installers"
    }

```

The new configuration items are `create_kms_key` and `kms_alias`.

### tf-mod-addon-logging-alb

No changes required if using at least version `tf-mod-addon-logging-alb-v1.3.0`.  Bucket ACLs are changed to allow for the alb logging bucket to accept Cloudfront logs via ACLs.

## Configuration Example

This example assumes that you used the following commands to create your public and private key for consumption by the module:

```
openssl genrsa -out cloudfront.key 2048
openssl rsa -pubout -in cloudfront.key -out cloudfront.pem
```

To be able to store these in source control in a sane manner, the objects will be KMS encrypted for storage at rest.  This can happen by having a KMS key as follows:

```

resource "aws_kms_key" "customer_data_key" {
  description = "key used to encrypt sensitive data stored in terraform"
}       
        
resource "aws_kms_alias" "alias" {
  name          = "alias/fleet-terraform-encrypted"
  target_key_id = aws_kms_key.customer_data_key.id
}       
      
output "kms_key_id" {
  value = aws_kms_key.customer_data_key.id
}  
```

Then with the key, the following `encrypt.sh` script encrypt the objects:

```
#!/bin/bash

set -e

function usage() {
	cat <<-EOUSAGE
	
	Usage: $(basename ${0}) <KMS_KEY_ID> <SOURCE> <DESTINATION> [AWS_PROFILE]
	
		This script encrypts an plaintext file from SOURCE into an
		AWS KMS encrypted DESTINATION file.  Optionally you
		may provide the AWS_PROFILE you wish to use to run the aws kms
		commands.

	EOUSAGE
	exit 1
}

[ $# -lt 3 ] && usage

if [ -n "${4}" ]; then
	export AWS_PROFILE=${4}
fi

aws kms encrypt --key-id "${1:?}" --plaintext fileb://<(cat "${2:?}") --output text --query CiphertextBlob > "${3:?}"
```

We can do the following with that script to encrypt the objects:

```
./encrypt.sh <KMS_KEY_ID> cloudfront.key cloudfront.key.encrypted
./encrypt.sh <KMS_KEY_ID> cloudfront.pem cloudfront.pem.encrypted

```

Now with those encrypted we could setup the module with something like the following to populate the module (assuming we add the files to a /resources folder):

```
module "cloudfront-software-installers" {
  source            = "github.com/fleetdm/fleet-terraform/addons/cloudfront-software-installers?ref=tf-mod-addon-cloudfront-software-installers-v1.0.0"
  customer          = "fleet"
  s3_bucket         = module.main.byo-vpc.byo-db.byo-ecs.fleet_s3_software_installers_config.bucket_name
  s3_kms_key_id     = module.main.byo-vpc.byo-db.byo-ecs.fleet_s3_software_installers_config.kms_key_id
  public_key        = data.aws_kms_secrets.cloudfront.plaintext["public_key"]
  private_key       = data.aws_kms_secrets.cloudfront.plaintext["private_key"]
  enable_logging    = true
  logging_s3_bucket = module.logging_alb.log_s3_bucket_id
}

data "aws_kms_secrets" "cloudfront" {
  secret {
    name    = "public_key"
    key_id  = aws_kms_key.customer_data_key.id
    payload = file("${path.module}/resources/cloudfront.pem.encrypted")
  }
  secret {
    name    = "private_key"
    key_id  = aws_kms_key.customer_data_key.id
    payload = file("${path.module}/resources/cloudfront.key.encrypted")
  }
}
```

Then we need to include outputs from this module once applied back into the main fleet-config under the `extra_secrets` and `extra_execution_roles`:

Under the `fleet_config` section.  If not using the mdm module, that could be omitted but was included to show how to include multiple extra items:

```
  fleet_config = {
  ...
    extra_execution_iam_policies = concat(
      module.mdm.extra_execution_iam_policies,
      module.cloudfront-software-installers.extra_execution_iam_policies,
    )
    extra_secrets = merge(
      module.mdm.extra_secrets,
      module.cloudfront-software-installers.extra_secrets
    )
 }

```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.88.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_cloudfront_software_installers"></a> [cloudfront\_software\_installers](#module\_cloudfront\_software\_installers) | terraform-aws-modules/cloudfront/aws | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_cloudfront_key_group.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_key_group) | resource |
| [aws_cloudfront_public_key.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_public_key) | resource |
| [aws_iam_policy.software_installers_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_kms_key_policy.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [aws_s3_bucket_policy.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_secretsmanager_secret.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.software_installers_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.software_installers_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.software_installers_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_s3_bucket.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |
| [aws_s3_bucket.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_customer"></a> [customer](#input\_customer) | Customer name for the cloudfront instance | `string` | `"fleet"` | no |
| <a name="input_enable_logging"></a> [enable\_logging](#input\_enable\_logging) | Enable optional logging to s3 | `bool` | `false` | no |
| <a name="input_logging_s3_bucket"></a> [logging\_s3\_bucket](#input\_logging\_s3\_bucket) | s3 bucket to log to | `string` | `null` | no |
| <a name="input_logging_s3_prefix"></a> [logging\_s3\_prefix](#input\_logging\_s3\_prefix) | logging s3 bucket prefix | `string` | `"cloudfront"` | no |
| <a name="input_private_key"></a> [private\_key](#input\_private\_key) | Private key used for signed URLs | `string` | n/a | yes |
| <a name="input_public_key"></a> [public\_key](#input\_public\_key) | Public key used for signed URLs | `string` | n/a | yes |
| <a name="input_s3_bucket"></a> [s3\_bucket](#input\_s3\_bucket) | Name of the S3 bucket that Cloudfront will point to | `string` | n/a | yes |
| <a name="input_s3_kms_key_id"></a> [s3\_kms\_key\_id](#input\_s3\_kms\_key\_id) | KMS key id used to encrypt the s3 bucket | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cloudfront_arn"></a> [cloudfront\_arn](#output\_cloudfront\_arn) | n/a |
| <a name="output_extra_execution_iam_policies"></a> [extra\_execution\_iam\_policies](#output\_extra\_execution\_iam\_policies) | n/a |
| <a name="output_extra_secrets"></a> [extra\_secrets](#output\_extra\_secrets) | n/a |
