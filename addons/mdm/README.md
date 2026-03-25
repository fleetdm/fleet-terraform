# MDM addon

Notice: Previous versions of this module referred to `dep`, but to reduce confusion that has been replaces with `abm`
to match the change to the newer Apple Business Manager.  For each key/value pair below, the key names have been changed
from previous version to match the name of the env var for easier usability.  Older unused env vars were also removed
for simplification.  This includes removing the need for `extra_environment_variables` completely.

This addon enables MDM functionality for Fleet. It does this via several secrets in AWS that stores the necessary values.
The following secrets are created:
- abm
- scep
- apn

To encrypt those secrets with a CMK, use `secrets_kms`. Supply `kms_key_arn` to use an existing key, or set `cmk_enabled = true` and leave `kms_key_arn = null` to have this module create a key using `kms_alias`.

If you are creating the MDM secrets CMK and this module's `extra_execution_iam_policies` output is fed back into the Fleet ECS execution role in the same stack, pass `secrets_kms.fleet_execution_role_name` as the stable execution role name string instead of trying to read it from a Fleet module output. That avoids introducing a cycle while still letting this module add the execution role to the CMK policy.

Note: ABM is optional.  If Apple Business Manager (ABM) is not used, set the abm variable to `null` and it will be omitted.

Since this module cannot determine the value for the secrets at apply time, this module must be applied in 2 phases:

1. In the first phase, just add the module without passing additional config to the main Fleet module
1. In the second phase, after the secret values have been populated, apply while also passing the additional config to the main Fleet module.

Example KMS configuration:

```
module "mdm" {
  source = "github.com/fleetdm/fleet-terraform/addons/mdm?depth=1&ref=tf-mod-addon-mdm-v2.0.0"

  apn_secret_name    = null
  scep_secret_name   = "fleet-scep"
  abm_secret_name    = null
  enable_apple_mdm   = false
  enable_windows_mdm = true

  secrets_kms = {
    cmk_enabled               = true
    kms_alias                 = "fleet-mdm-secrets"
    kms_base_policy           = local.kms_base_policy_statements
    fleet_execution_role_name = "fleet-execution-role"
  }
}
```

The secrets should have the following layouts, note that all values are strings. If a value is a JSON object, string escape it.:
## ABM
```
{
    "FLEET_MDM_APPLE_BM_CERT_BYTES": <ABM cert>,
    "FLEET_MDM_APPLE_BM_KEY_BYTES": <ABM key>,
    "FLEET_MDM_APPLE_BM_SERVER_TOKEN_BYTES": <ABM p7m token>
}
```

## SCEP
```
{
    "FLEET_MDM_APPLE_SCEP_CERT_BYTES": <SCEP cert>,
    "FLEET_MDM_APPLE_SCEP_KEY_BYTES": <SCEP key>,
    "FLEET_MDM_APPLE_SCEP_CHALLENGE": <SCEP challenge>
}
```

Please note that for Windows, the same SCEP cert is used and the cert+key above will populate the following environment variables:
```
    "FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT_BYTES"
    "FLEET_MDM_WINDOWS_WSTEP_IDENTITY_KEY_BYTES"
```
## APN
```
{
    "FLEET_MDM_APPLE_APNS_CERT_BYTES": <APNS cert>,
    "FLEET_MDM_APPLE_APNS_KEY_BYTES ": <APNS key>
}
```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_kms_alias.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_secretsmanager_secret.abm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.apn](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.scep](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secrets_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_role.fleet_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |
| [aws_kms_key.provided](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_abm_secret_name"></a> [abm\_secret\_name](#input\_abm\_secret\_name) | n/a | `string` | `"fleet-abm"` | no |
| <a name="input_apn_secret_name"></a> [apn\_secret\_name](#input\_apn\_secret\_name) | n/a | `string` | `"fleet-apn"` | no |
| <a name="input_enable_apple_mdm"></a> [enable\_apple\_mdm](#input\_enable\_apple\_mdm) | n/a | `bool` | `true` | no |
| <a name="input_enable_windows_mdm"></a> [enable\_windows\_mdm](#input\_enable\_windows\_mdm) | n/a | `bool` | `false` | no |
| <a name="input_scep_secret_name"></a> [scep\_secret\_name](#input\_scep\_secret\_name) | n/a | `string` | `"fleet-scep"` | no |
| <a name="input_secrets_kms"></a> [secrets\_kms](#input\_secrets\_kms) | Configuration for optional customer-managed KMS encryption of the MDM Secrets Manager secrets. | <pre>object({<br/>    cmk_enabled = optional(bool, false)<br/>    kms_key_arn = optional(string, null)<br/>    kms_alias   = optional(string, "fleet-mdm-secrets")<br/>    kms_base_policy = optional(list(object({<br/>      sid    = string<br/>      effect = string<br/>      principals = object({<br/>        type        = string<br/>        identifiers = list(string)<br/>      })<br/>      actions   = list(string)<br/>      resources = list(string)<br/>      conditions = optional(list(object({<br/>        test     = string<br/>        variable = string<br/>        values   = list(string)<br/>      })), [])<br/>    })), null)<br/>    extra_kms_policies        = optional(list(any), [])<br/>    fleet_execution_role_name = optional(string, null)<br/>  })</pre> | <pre>{<br/>  "cmk_enabled": false,<br/>  "extra_kms_policies": [],<br/>  "fleet_execution_role_name": null,<br/>  "kms_alias": "fleet-mdm-secrets",<br/>  "kms_base_policy": null,<br/>  "kms_key_arn": null<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_abm"></a> [abm](#output\_abm) | n/a |
| <a name="output_apn"></a> [apn](#output\_apn) | n/a |
| <a name="output_extra_execution_iam_policies"></a> [extra\_execution\_iam\_policies](#output\_extra\_execution\_iam\_policies) | n/a |
| <a name="output_extra_secrets"></a> [extra\_secrets](#output\_extra\_secrets) | n/a |
| <a name="output_scep"></a> [scep](#output\_scep) | n/a |
