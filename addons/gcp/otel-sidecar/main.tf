# This addon outputs the Fleet env vars needed to enable OpenTelemetry export
# to an OTLP gRPC receiver on localhost:4317. It does not provision a sidecar
# container itself — callers wire their preferred collector (DDOT,
# otelcol-contrib, Grafana Alloy, Honeycomb agent, ...) via the gcp module's
# var.sidecar_containers input.
#
# See the README for example sidecar definitions.

locals {
  resource_attributes = join(",", concat(
    [
      "service.name=${var.service_name}",
      "deployment.environment=${var.deployment_environment}",
    ],
    var.service_version != null ? ["service.version=${var.service_version}"] : [],
    [for k, v in var.extra_resource_attributes : "${k}=${v}"],
  ))
}
