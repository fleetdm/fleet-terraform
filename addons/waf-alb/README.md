# WAF for ALB addon
This addon creates and manages WAF attached to an ALB

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.9.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_wafv2_ip_set.allowed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_ip_set) | resource |
| [aws_wafv2_ip_set.blocked](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_ip_set) | resource |
| [aws_wafv2_regex_pattern_set.bypass_urls](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_regex_pattern_set) | resource |
| [aws_wafv2_rule_group.allowed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_rule_group) | resource |
| [aws_wafv2_rule_group.blocked](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_rule_group) | resource |
| [aws_wafv2_web_acl.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [aws_wafv2_web_acl_association.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_association) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allowed_addresses"></a> [allowed\_addresses](#input\_allowed\_addresses) | n/a | `list(string)` | `[]` | no |
| <a name="input_blocked_addresses"></a> [blocked\_addresses](#input\_blocked\_addresses) | n/a | `list(string)` | `[]` | no |
| <a name="input_blocked_countries"></a> [blocked\_countries](#input\_blocked\_countries) | n/a | `list(string)` | <pre>[<br/>  "BI",<br/>  "BY",<br/>  "CD",<br/>  "CF",<br/>  "CU",<br/>  "IQ",<br/>  "IR",<br/>  "LB",<br/>  "LY",<br/>  "SD",<br/>  "SO",<br/>  "SS",<br/>  "SY",<br/>  "VE",<br/>  "ZW",<br/>  "RU"<br/>]</pre> | no |
| <a name="input_bypass_urls"></a> [bypass\_urls](#input\_bypass\_urls) | Optional list of regex patterns for URL paths that bypass the IP allowlist WAF rule.<br/>The patterns must be valid AWS WAF regex strings. | `list(string)` | `[]` | no |
| <a name="input_capacity"></a> [capacity](#input\_capacity) | The capacity required to handle the rules. | `number` | `2` | no |
| <a name="input_lb_arn"></a> [lb\_arn](#input\_lb\_arn) | n/a | `any` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | n/a | `any` | n/a | yes |
| <a name="input_waf_type"></a> [waf\_type](#input\_waf\_type) | n/a | `string` | `"blocklist"` | no |

## Outputs

No outputs.
