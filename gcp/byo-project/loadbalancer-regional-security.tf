# Cloud Armor allowlist policy (regional load balancer only, off by default).
#
# Semantics (operator-owned, nothing is allowed automatically):
#   * cloud_armor.allowed_ip_ranges  -> those sources may reach ANY path.
#   * cloud_armor.allow_public_paths -> paths matching these RE2 regexes may be
#                                       reached from ANY source.
#   * everything else                -> deny(403) via the default rule below.
# Either list may be empty (e.g. an IP-only policy); enabling with both empty is
# rejected by variable validation because it would deny all traffic.
#
# The policy is attached natively through the google-beta regional backend's
# security_policy field in loadbalancer-regional.tf, after these rules exist.
resource "google_compute_region_security_policy" "regional_security_policy" {
  count       = local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable ? 1 : 0
  name        = "${var.prefix}-regional-security-policy"
  region      = var.region
  project     = var.project_id
  description = "Cloud Armor policy to restrict admin access while allowing public device endpoints"
  type        = "CLOUD_ARMOR"
}

# ================================================================================
# Public Path Allow Rules (priorities 1000+)
# ================================================================================
# Any request whose path matches one of these regexes is allowed from any source
# IP (bypassing the IP allowlist). Sourced entirely from
# cloud_armor.allow_public_paths — the operator decides which paths are public.
# Paths are chunked into groups of 5 (Cloud Armor's per-rule CEL limit), one
# rule per chunk, priorities 1000/1010/1020/...
#
# Each pattern is embedded as a CEL double-quoted string literal produced by
# jsonencode(). JSON string escaping (\" , \\ , \n, \uXXXX) is valid CEL
# string escaping, so a pattern containing quotes or backslashes cannot
# terminate the literal or inject CEL, and CEL decodes the literal back to the
# exact regex the operator supplied (e.g. "^/a\\.b$" in CEL is the regex ^/a\.b$).

locals {
  # Cloud Armor caps CEL sub-expressions at 5 per rule.
  public_path_chunks = chunklist(var.cloud_armor.allow_public_paths, 5)
  # Cloud Armor caps src_ip_ranges at 10 per rule.
  ip_chunks = chunklist(var.cloud_armor.allowed_ip_ranges, 10)
}

resource "google_compute_region_security_policy_rule" "allow_public_paths" {
  for_each = {
    for idx, paths in local.public_path_chunks : idx => paths
    if local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable
  }

  project         = var.project_id
  region          = var.region
  security_policy = google_compute_region_security_policy.regional_security_policy[0].name
  description     = "Allow public path chunk ${each.key + 1}/${length(local.public_path_chunks)}"
  priority        = 1000 + each.key * 10
  action          = "allow"

  match {
    expr {
      expression = join(" || ", [
        for p in each.value : "request.path.matches(${jsonencode(p)})"
      ])
    }
  }
}

# ================================================================================
# Source IP Allowlist (10 ranges per rule, one rule per chunk, priorities 2000+)
# ================================================================================
# Requests from cloud_armor.allowed_ip_ranges are allowed for any path.

resource "google_compute_region_security_policy_rule" "allow_admin_ips" {
  for_each = {
    for idx, chunk in local.ip_chunks : tostring(idx) => chunk
    if local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable
  }

  project         = var.project_id
  region          = var.region
  security_policy = google_compute_region_security_policy.regional_security_policy[0].name
  description     = "Allow admin IP ranges (chunk ${tonumber(each.key) + 1}/${length(local.ip_chunks)})"
  priority        = 2000 + tonumber(each.key) * 10
  action          = "allow"

  match {
    versioned_expr = "SRC_IPS_V1"
    config {
      src_ip_ranges = each.value
    }
  }
}

# ================================================================================
# Default Deny Rule
# ================================================================================

# Rule: Default deny all other traffic - priority 2147483647 (max)
#
# Keep this priority. Cloud Armor creates every policy with an implicit default
# rule at priority 2147483647 (match "*", action allow). That rule cannot be
# deleted or duplicated; managing a rule at this exact priority makes the
# provider patch the existing default rule to deny(403) instead of creating a
# new one. Moving it to another priority would leave the implicit allow-all
# default rule in place.
resource "google_compute_region_security_policy_rule" "default_deny" {
  count           = local.lb_config.enable && local.lb_config.use_regional_lb && var.cloud_armor.enable ? 1 : 0
  project         = var.project_id
  region          = var.region
  security_policy = google_compute_region_security_policy.regional_security_policy[0].name
  description     = "Default deny all other traffic"
  priority        = 2147483647
  action          = "deny(403)"

  match {
    versioned_expr = "SRC_IPS_V1"
    config {
      src_ip_ranges = ["*"]
    }
  }
}
