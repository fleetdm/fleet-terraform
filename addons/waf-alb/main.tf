locals {
  default_action = var.waf_type == "blocklist" ? "block" : "allow"
}

resource "aws_wafv2_rule_group" "blocked" {
  count    = var.waf_type == "blocklist" ? 1 : 0
  name     = var.name
  scope    = "REGIONAL"
  capacity = var.capacity

  rule {
    name     = "countries"
    priority = 1

    action {
      block {}
    }

    statement {
      geo_match_statement {
        country_codes = var.blocked_countries
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = var.name
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "specific"
    priority = 2

    action {
      block {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocked[0].arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = var.name
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = var.name
    sampled_requests_enabled   = false
  }
}

resource "aws_wafv2_ip_set" "blocked" {
  count              = var.waf_type == "blocklist" ? 1 : 0
  name               = var.name
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.blocked_addresses
}

resource "aws_wafv2_rule_group" "allowed" {
  count    = var.waf_type == "allowlist" ? 1 : 0
  name     = var.name
  scope    = "REGIONAL"
  capacity = var.capacity

  rule {
    name     = "specific"
    priority = 1

    action {
      allow {}
    }

    statement {
      or_statement {
        # Dynamic bypass regex statements
        dynamic "statement" {
          for_each = length(var.bypass_urls) > 0 ? [1] : []
          content {
            regex_pattern_set_reference_statement {
              arn = aws_wafv2_regex_pattern_set.bypass_urls[0].arn

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
        }
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.allowed[0].arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = var.name
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = var.name
    sampled_requests_enabled   = false
  }
}

resource "aws_wafv2_web_acl" "main" {
  name  = var.name
  scope = "REGIONAL"

  default_action {
    dynamic "block" {
      for_each = var.waf_type == "allowlist" ? [true] : []
      content {}
    }
    dynamic "allow" {
      for_each = var.waf_type == "blocklist" ? [true] : []
      content {}
    }
  }

  rule {
    name     = "rule-1"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rule_group_reference_statement {
        arn = var.waf_type == "blocklist" ? aws_wafv2_rule_group.blocked[0].arn : aws_wafv2_rule_group.allowed[0].arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = var.name
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = var.name
    sampled_requests_enabled   = false
  }
}

resource "aws_wafv2_ip_set" "allowed" {
  count              = var.waf_type == "allowlist" ? 1 : 0
  name               = var.name
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_addresses
}

resource "aws_wafv2_regex_pattern_set" "bypass_urls" {
  # Only works for allowlists
  count = length(var.bypass_urls) > 0 && var.waf_type == "allowlist" ? 1 : 0

  name  = var.name
  scope = "REGIONAL"

  dynamic "regular_expression" {
    for_each     = toset(var.bypass_urls)
    content {
      regex_string = regular_expression.value
    }
  }
}

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = var.lb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
