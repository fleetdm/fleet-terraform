variable "manage_existing_project_apis" {
  description = "Opt in to enabling the baseline Fleet APIs plus extra_apis on an existing project (create_project = false). APIs are never disabled on destroy. Has no effect when create_project = true; the project factory already enables these APIs."
  type        = bool
  default     = false
  nullable    = false
}

locals {
  # Baseline APIs needed by the Fleet stack. Shared by the project factory
  # (create_project = true) and the opt-in existing-project API management
  # below so the two paths cannot drift apart.
  baseline_project_apis = [
    "compute.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "run.googleapis.com",
    "vpcaccess.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "memorystore.googleapis.com",
    "serviceconsumermanagement.googleapis.com",
    "networkconnectivity.googleapis.com",
    "certificatemanager.googleapis.com",
  ]

  # Only populated for existing projects whose operator opted in. Duplicates
  # between the baseline and extra_apis collapse in the set.
  existing_project_apis = !var.create_project && var.manage_existing_project_apis ? toset(concat(local.baseline_project_apis, var.extra_apis)) : toset([])
}

# Enable APIs on an existing project. disable_on_destroy = false so that
# destroying (or later opting out of) this stack never turns off APIs the
# project may have relied on before Fleet was deployed.
resource "google_project_service" "existing_project_apis" {
  for_each = local.existing_project_apis

  project                    = var.project_id
  service                    = each.key
  disable_on_destroy         = false
  disable_dependent_services = false
}
