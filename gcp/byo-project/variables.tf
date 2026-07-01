variable "project_id" {
  description = "GCP project ID"
}

variable "location" {
  default = "us"
}

variable "region" {
  default = "us-central1"
}

variable "prefix" {
  default = "fleet"
}

variable "dns_zone_name" {
  description = "The DNS name of the managed zone (e.g., 'my-fleet-infra.com.')"
  type        = string
}

variable "dns_record_name" {
  description = "The DNS record for Fleet (e.g., 'fleet.my-fleet-infra.com.')"
  type        = string
}

variable "cache_config" {
  type = object({
    name           = string
    tier           = string
    engine_version = string
    connect_mode   = string
    memory_size    = number
  })
  default = {
    name           = "fleet-cache"
    tier           = "STANDARD_HA"
    engine_version = null // defaults to version 7
    connect_mode   = "PRIVATE_SERVICE_ACCESS"
    memory_size    = 1
  }
}

variable "database_config" {
  type = object({
    name                = string
    database_name       = string
    database_user       = string
    collation           = string
    charset             = string
    deletion_protection = bool
    database_version    = string
    tier                = string
  })
  default = {
    name                = "fleet-mysql"
    database_name       = "fleet"
    database_user       = "fleet"
    collation           = "utf8mb4_unicode_ci"
    charset             = "utf8mb4"
    deletion_protection = false
    database_version    = "MYSQL_8_0"
    tier                = "db-n1-standard-1"
  }
}

variable "vpc_config" {
  type = object({
    network_name = string
    subnets = list(object({
      subnet_name           = string
      subnet_ip             = string
      subnet_region         = string
      subnet_private_access = bool
    }))
  })

  default = {
    network_name = "fleet-network"
    subnets = [
      {
        subnet_name           = "fleet-subnet"
        subnet_ip             = "10.10.10.0/24"
        subnet_region         = "us-central1"
        subnet_private_access = true
      }
    ]
  }

}

variable "sidecar_containers" {
  description = <<-EOT
    Optional sidecar containers to run alongside Fleet in the fleet-api Cloud
    Run service. Shape matches the cloud-run module's container object.

    Useful for OpenTelemetry collectors (otelcol-contrib, Datadog DDOT, Grafana
    Alloy, etc.) that expose an OTLP receiver Fleet can ship traces, metrics,
    and logs into via its built-in OTel SDK exporters.

    Requirements imposed by Cloud Run:

      - Each sidecar must declare a startup_probe. Cloud Run rejects any
        depends_on reference to a container without one.
      - Only one container per service may own the ingress port. Set
        ports = { name = "", container_port = 0 } on sidecars to opt out
        (requires the cloud-run v2 module to accept container_port = 0 as a
        "no exposed port" sentinel — see
        https://github.com/GoogleCloudPlatform/terraform-google-cloud-run/pull/450).
  EOT
  type = list(object({
    container_name       = string
    container_image      = string
    container_args       = optional(list(string))
    container_command    = optional(list(string))
    depends_on_container = optional(list(string))
    env_vars             = optional(map(string), {})
    env_secret_vars = optional(map(object({
      secret  = string
      version = string
    })), {})
    ports = optional(object({
      name           = optional(string)
      container_port = optional(number)
    }))
    resources = optional(object({
      limits = optional(object({
        cpu    = optional(string)
        memory = optional(string)
      }))
      cpu_idle          = optional(bool, true)
      startup_cpu_boost = optional(bool, false)
    }), {})
    startup_probe = optional(object({
      failure_threshold     = optional(number)
      initial_delay_seconds = optional(number)
      timeout_seconds       = optional(number)
      period_seconds        = optional(number)
      tcp_socket = optional(object({
        port = optional(number)
      }))
    }))
  }))
  default = []
}

variable "service_only_env_vars" {
  description = <<-EOT
    Extra env vars applied only to the fleet-api Cloud Run service, not the
    migration job. Use this for vars that depend on a sidecar container being
    present, such as OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 — the
    migration job runs as a Cloud Run Job with no sidecars, so localhost:4317
    has no listener and the OTel exporter would log retry errors during the
    brief job run.
  EOT
  type        = map(string)
  default     = {}
}

variable "fleet_config" {
  type = object({
    installers_bucket_name = string
    image_tag              = string
    fleet_cpu              = string
    fleet_memory           = string
    debug_logging          = bool
    license_key            = optional(string)
    min_instance_count     = number
    max_instance_count     = number
    exec_migration         = bool
    use_h2c                = bool
    extra_env_vars         = optional(map(string))
    extra_secret_env_vars = optional(map(object({
      secret  = string
      version = string
    })))
  })
  default = {
    image_tag              = "fleetdm/fleet:v4.87.1"
    installers_bucket_name = ""
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    use_h2c                = false
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
  }
}
