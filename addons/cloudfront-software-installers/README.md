# Cloudfront Software Installers

This module allows for Fleet software installers to be served via AWS Cloudfront instead of directly from Fleet.

This should improve the performance of software installer delivery.  For general information about Fleet and Cloudfront see the following:

https://fleetdm.com/guides/cdn-signed-urls
https://victoronsoftware.com/posts/cloudfront-signed-urls/

The second link includes a script that can be used to test and see if signed URLs are working outside of Fleet for troubleshooting purposes.

## AWS GovCloud Scope

This addon is intentionally out of scope for AWS GovCloud compatibility. CloudFront is not available inside the AWS GovCloud (US) partition, so using it with GovCloud-hosted resources is a cross-partition architecture that should be designed and reviewed separately.

## S3 Bucket Policy

This addon no longer manages an S3 bucket policy on the software installers bucket. The bucket policy is now managed by the core module (`byo-ecs`), which automatically denies non-HTTPS requests and includes the CloudFront allow statement when `cloudfront_distribution_arn` is set.

## Other module requirements

These are the minimum versions of modules required if used:

 - tf-mod-root-v1.30.0
 - tf-mod-byo-vpc-v1.31.0
 - tf-mod-byo-db-v1.21.0
 - tf-mod-byo-ecs-v1.21.0
 - tf-mod-addon-logging-alb-v1.3.0

Previous versions do not allow for proper interaction with both the software installers and logging s3 buckets.

## Blue-Green Key Rotation

This module supports rotating CloudFront signing keys without invalidating existing signed URLs. Instead of a single `public_key` / `private_key` pair, you can provide a map of named keypairs and select which one is active:

```hcl
module "cloudfront-software-installers" {
  source      = "..."
  customer    = "fleet"
  s3_bucket   = module.main.byo-vpc.byo-db.byo-ecs.fleet_s3_software_installers_config.bucket_name

  keypairs = {
    current = {
      public_key  = data.aws_kms_secrets.cloudfront.plaintext["public_key"]
      private_key = data.aws_kms_secrets.cloudfront.plaintext["private_key"]
    }
    next = {
      public_key  = data.aws_kms_secrets.cloudfront_next.plaintext["public_key"]
      private_key = data.aws_kms_secrets.cloudfront_next.plaintext["private_key"]
    }
  }

  active_keypair_name = "current"
}
```

All keypairs in the map are added to the CloudFront key group, so signed URLs created by any retained key remain valid. Only the active keypair populates the Secrets Manager secret that Fleet reads.

### Rotation procedure

1. **Upgrade the module** with the existing key only (or via the legacy `public_key` / `private_key` inputs). Confirm Terraform plans only a resource move (`aws_cloudfront_public_key.software_installers[0]` → `["current"]`) with no create/update/delete.
2. **Add the new keypair** under any new map name (e.g. `next`), leaving `active_keypair_name = "current"`. Apply and wait for the CloudFront key group update to deploy.
3. **Flip the active key** by changing `active_keypair_name` to the new key name and applying. This creates a new Secrets Manager secret version.
4. **Redeploy Fleet ECS tasks** so the container receives the updated secret values.
5. **Retire the old keypair** after the maximum signed URL lifetime has passed. Remove it from the map and apply. If CloudFront reports the old public key is still in use, wait for propagation and apply again.

### Legacy inputs

The `public_key` and `private_key` variables are deprecated but still supported. When `keypairs` is not set, they are normalized into a single `current` keypair internally. Migrate to the `keypairs` map at your convenience.

### External key groups

Blue-green key rotation is not supported when `key_group_id` is set. When using an external key group, the module cannot manage the public key resources, so `active_keypair_name` cannot select the correct public key ID. Use `keypairs` only when the module manages the key group (i.e., `key_group_id` is not set).

## Configuration considerations for other modules

### tf-mod-root/tf-mod-byo-vpc/tf-mod-byo-db/tf-mod-byo-ecs

For any of these modules, software installers requires a customer-managed KMS key whenever KMS encryption is used at all. CloudFront access requires a key policy statement on that key, and the AWS-managed default key cannot be modified to accept that policy.

Breaking change: this addon no longer manages the software installers KMS key policy. That policy now lives in `tf-mod-byo-ecs`, which means CloudFront access to the CMK must be configured there by setting `software_installers.cloudfront_distribution_arn` to the static distribution ARN.

This is the relevant configuration starting at the software installers configuration block:

```
    software_installers = {
      bucket_prefix               = "fleet-software-installers-"
      create_kms_key              = true
      kms_alias                   = "fleet-software-installers"
      cloudfront_distribution_arn = "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>"
    }

```

The required configuration items here are `create_kms_key`, `kms_alias`, and `cloudfront_distribution_arn` when CloudFront must read from an SSE-KMS bucket.

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
  source            = "github.com/fleetdm/fleet-terraform/addons/cloudfront-software-installers?ref=tf-mod-addon-cloudfront-software-installers-v3.0.0"
  customer          = "fleet"
  s3_bucket         = module.main.byo-vpc.byo-db.byo-ecs.fleet_s3_software_installers_config.bucket_name
  # OPTIONAL
  # If you'd like to use an existing key_group_id for your new Cloudfront distribution, uncomment key_group_id and supply the value for the key_group_id
  # If you're using an existing key_group_id, public_key_id is required. The public_key_id is the value of a public_key that is also part of the key group that you define.
  # key_group_id      = ""
  # public_key_id     = ""
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

This addon also outputs `cloudfront_distribution_arn`. Do not feed that output back into `tf-mod-byo-ecs`, because that creates a Terraform cycle. Instead, set the same static ARN directly in `software_installers.cloudfront_distribution_arn`.

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
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_cloudfront_software_installers"></a> [cloudfront\_software\_installers](#module\_cloudfront\_software\_installers) | terraform-aws-modules/cloudfront/aws | 5.2.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudfront_key_group.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_key_group) | resource |
| [aws_cloudfront_public_key.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_public_key) | resource |
| [aws_iam_policy.software_installers_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_secretsmanager_secret.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_iam_policy_document.software_installers_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_s3_bucket.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |
| [aws_s3_bucket.software_installers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_active_keypair_name"></a> [active\_keypair\_name](#input\_active\_keypair\_name) | Name of the keypair in `keypairs` (or `"current"` when using legacy inputs) whose keys populate the Secrets Manager secret. All keypairs in the map are added to the CloudFront key group so signed URLs from any retained key remain valid. | `string` | `"current"` | no |
| <a name="input_customer"></a> [customer](#input\_customer) | Customer name for the cloudfront instance | `string` | `"fleet"` | no |
| <a name="input_enable_logging"></a> [enable\_logging](#input\_enable\_logging) | Enable optional logging to s3 | `bool` | `false` | no |
| <a name="input_key_group_id"></a> [key\_group\_id](#input\_key\_group\_id) | Cloudfront key group id | `string` | `null` | no |
| <a name="input_keypairs"></a> [keypairs](#input\_keypairs) | Map of named keypairs for blue-green key rotation. Each value must contain `public_key` and `private_key`. When set, `public_key` and `private_key` variables are ignored. | <pre>map(object({<br/>    public_key  = string<br/>    private_key = string<br/>  }))</pre> | `null` | no |
| <a name="input_logging_s3_bucket"></a> [logging\_s3\_bucket](#input\_logging\_s3\_bucket) | s3 bucket to log to | `string` | `null` | no |
| <a name="input_logging_s3_prefix"></a> [logging\_s3\_prefix](#input\_logging\_s3\_prefix) | logging s3 bucket prefix | `string` | `"cloudfront"` | no |
| <a name="input_private_key"></a> [private\_key](#input\_private\_key) | Private key used for signed URLs. Deprecated: use `keypairs` instead. | `string` | `null` | no |
| <a name="input_public_key"></a> [public\_key](#input\_public\_key) | Public key used for signed URLs. Deprecated: use `keypairs` instead. | `string` | `null` | no |
| <a name="input_public_key_id"></a> [public\_key\_id](#input\_public\_key\_id) | Cloudfront public key id. Required when passing in a key\_group\_id | `string` | `null` | no |
| <a name="input_s3_bucket"></a> [s3\_bucket](#input\_s3\_bucket) | Name of the S3 bucket that Cloudfront will point to | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cloudfront_arn"></a> [cloudfront\_arn](#output\_cloudfront\_arn) | n/a |
| <a name="output_cloudfront_distribution_arn"></a> [cloudfront\_distribution\_arn](#output\_cloudfront\_distribution\_arn) | n/a |
| <a name="output_extra_execution_iam_policies"></a> [extra\_execution\_iam\_policies](#output\_extra\_execution\_iam\_policies) | n/a |
| <a name="output_extra_secrets"></a> [extra\_secrets](#output\_extra\_secrets) | n/a |
