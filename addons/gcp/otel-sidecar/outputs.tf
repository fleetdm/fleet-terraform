output "fleet_extra_environment_variables" {
  description = "Env vars to pass to module.fleet.fleet_config.extra_env_vars (for the migration job) and var.service_only_env_vars (for the Cloud Run service). The OTLP endpoint var is service-only since the migration job runs without sidecars."
  value = {
    # Universal across job + service: enables Fleet's OTel SDK init. Safe
    # because if no collector is reachable, the SDK silently retries with
    # exponential backoff — no Fleet-side error.
    universal = {
      FLEET_LOGGING_TRACING_ENABLED   = "true"
      FLEET_LOGGING_OTEL_LOGS_ENABLED = var.enable_otel_logs ? "true" : "false"
      OTEL_SERVICE_NAME               = var.service_name
      OTEL_RESOURCE_ATTRIBUTES        = local.resource_attributes
    }
    # Service-only: depends on a sidecar listening at this address. The
    # migration job runs without sidecars, so it must not see these.
    service_only = {
      OTEL_EXPORTER_OTLP_ENDPOINT = var.otlp_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL = "grpc"
      # The Go OTel SDK defaults to TLS; localhost is plaintext.
      OTEL_EXPORTER_OTLP_INSECURE = "true"
    }
  }
}
