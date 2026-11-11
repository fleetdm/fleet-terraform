# TEST-ONLY fixture: drives the lifecycle module with the REAL google-beta,
# terracurl, time and terraform_data providers against a LOOPBACK fake API
# (fake_cloud_run.py) with a FAKE token and fictional project. It provisions
# no SQL/Redis/LB. Never point this at real Google endpoints.
#
# providers_pin.tf (written by run_scenarios.py) pins the provider versions.

variable "fake_port" {
  type = number
}

variable "fake_token" {
  type      = string
  sensitive = true

  validation {
    condition     = startswith(var.fake_token, "fake-")
    error_message = "fixture refuses non-fake tokens"
  }
}

variable "image" {
  type    = string
  default = "fleetdm/fleet:v4.93.0"
}

variable "extra_env" {
  type    = map(string)
  default = {}
}

# Mirrors the real GCP root: fleet_config is sensitive as a whole, so the min
# instance count it forwards carries a sensitivity mark. The module must not
# interpolate it into lifecycle error diagnostics (Terraform then refuses the
# message and emits a warning instead of the real failure).
variable "min_instance_count" {
  type      = number
  sensitive = true
  default   = 1
}

# Short interval for the module's bounded control-plane settlement wait: the
# real default is 30s (one wait of 7x = 210s); tests must not wait minutes.
variable "restore_settle_interval_seconds" {
  type    = number
  default = 1
}

variable "drain_seconds" {
  type    = number
  default = 2
}

locals {
  endpoint = "http://127.0.0.1:${var.fake_port}/v2"
}

locals {
  fleet_service_name = "fleet-api"
}

provider "google-beta" {
  project                      = "fictional-proj"
  region                       = "us-central1"
  access_token                 = var.fake_token
  cloud_run_v2_custom_endpoint = "${local.endpoint}/"
}

# Stand-in for the Cloud SQL instance: its `output` is computed, so
# `-replace=terraform_data.fake_sql` plans it unknown even though the final
# string is identical (same-name replacement analogue).
resource "terraform_data" "fake_sql" {
  input = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d"
}

module "lifecycle" {
  source = "../../../gcp/byo-project/modules/fleet-lifecycle"

  project_id            = "fictional-proj"
  region                = "us-central1"
  service_name          = local.fleet_service_name
  image                 = var.image
  service_account_email = "fleet-run-sa@fictional-proj.iam.gserviceaccount.com"
  vpc_network           = "projects/fictional-proj/global/networks/fleet-network"
  vpc_subnetwork        = "fleet-subnet"
  cpu                   = "1000m"
  memory                = "4096Mi"
  min_instance_count    = var.min_instance_count
  max_instance_count    = 5
  env = merge({
    FLEET_LICENSE_KEY    = "fake-license-not-real"
    FLEET_MYSQL_ADDRESS  = "10.0.0.3:3306"
    FLEET_MYSQL_DATABASE = "fleet"
  }, var.extra_env)
  secret_env = {
    FLEET_MYSQL_PASSWORD = { secret = "fleet-db-password", version = "latest" }
  }
  database_identity = {
    sql_connection_name = terraform_data.fake_sql.output
    database_name       = "fleet"
  }

  run_api_base_url       = local.endpoint
  drain_seconds          = var.drain_seconds
  operation_wait_seconds = 5
  job_create_timeout     = "10m"

  restore_settle_interval_seconds = var.restore_settle_interval_seconds
}

# Stand-in for the root's serverless NEGs and the load balancer that depends
# on them with create_before_destroy. run_scenarios.py substitutes the root's
# actual NEG `service` expressions (global, regional) into `input`, so a NEG
# that references the lifecycle module's service also propagates
# create_before_destroy to the migration job here.
resource "terraform_data" "neg" {
  input = [local.fleet_service_name, local.fleet_service_name] # ROOT_NEG_SERVICE_REFS
}

resource "terraform_data" "lb" {
  input = terraform_data.neg.output

  lifecycle {
    create_before_destroy = true
  }
}

output "identity" {
  value = module.lifecycle.migration_identity
}

output "job_name" {
  value = module.lifecycle.migration_job_name
}

output "declared_scaling_mode" {
  value = module.lifecycle.declared_scaling_mode
}
