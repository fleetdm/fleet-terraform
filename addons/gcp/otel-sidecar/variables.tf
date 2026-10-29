variable "service_name" {
  description = "OTel service.name resource attribute. Surfaces in backends as the service tag/dimension."
  type        = string
  default     = "fleet"
}

variable "service_version" {
  description = "OTel service.version resource attribute. Recommended: set to the Fleet image tag (e.g. \"v4.85.0\") so per-release attribution works in the backend."
  type        = string
  default     = null
}

variable "deployment_environment" {
  description = "OTel deployment.environment resource attribute (e.g. \"prod\", \"staging\")."
  type        = string
  default     = "prod"
}

variable "extra_resource_attributes" {
  description = "Additional OTel resource attributes merged into OTEL_RESOURCE_ATTRIBUTES. Useful for custom tags like {team = \"sre\", region = \"us-central1\"}."
  type        = map(string)
  default     = {}
}

variable "otlp_endpoint" {
  description = "OTLP gRPC endpoint Fleet's OTel SDK exporters target. Defaults to the localhost sidecar pattern; override only if you're routing through a different listener (e.g. a Unix socket or an inline DDOT subprocess port)."
  type        = string
  default     = "http://localhost:4317"
}

variable "enable_otel_logs" {
  description = "Enable Fleet's OTel logs exporter (FLEET_LOGGING_OTEL_LOGS_ENABLED). Logs ship to the same OTLP endpoint as traces and metrics. Set to false if your collector doesn't accept OTLP logs (notably gcr.io/datadoghq/serverless-init — see datadog-agent#34097)."
  type        = bool
  default     = true
}
