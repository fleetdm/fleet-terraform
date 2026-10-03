# GCP OpenTelemetry Sidecar — Cloud Run

Wires Fleet's built-in OpenTelemetry SDK to a sidecar collector running alongside `fleet-api` on Cloud Run. Ships traces, metrics, and logs through whatever collector you mount (Datadog DDOT, the upstream OpenTelemetry Collector, Grafana Alloy, Honeycomb agent, ...).

This addon emits **environment variables only**. You provide the sidecar container yourself via the GCP module's `sidecar_containers` input — examples below.

## Why

Fleet emits OTLP/gRPC for all three signal types (`otlptracegrpc`, `otlpmetricgrpc`, `otlploggrpc`). You can ship that data through any OTel-compatible backend by running a collector as a sidecar in the same Cloud Run instance and pointing Fleet at `localhost:4317`.

Compared to Fleet's other observability paths:

| Path | What it covers | Where it goes |
| ---- | -------------- | ------------- |
| `addons/logging-destination-*` | osquery scheduled query / status / activity audit logs | SaaS log backends |
| **This addon** | **Fleet *server* traces, metrics, logs** (everything except osquery results) | Any OTel-compatible backend |
| `addons/xrays-sidecar` | Fleet server traces (AWS-only) | AWS X-Ray |

## Prerequisites

The GCP module must accept multi-container Cloud Run services, which requires the upstream `GoogleCloudPlatform/cloud-run/google//modules/v2` module to support sidecars without a `ports` block. That fix is being tracked in [GoogleCloudPlatform/terraform-google-cloud-run#450](https://github.com/GoogleCloudPlatform/terraform-google-cloud-run/pull/450) — until it merges, attempting to deploy with `var.sidecar_containers` will fail with:

```
Error 400: Revision template should contain exactly one container with an exposed port.
```

Until upstream merges, you can vendor the patched module locally; this addon's outputs are unaffected by where the cloud-run module comes from.

## Usage

```hcl
module "fleet_otel" {
  source = "github.com/fleetdm/fleet-terraform//addons/gcp/otel-sidecar?ref=main"

  service_name           = "fleet"
  service_version        = "v4.85.0" # match var.fleet_config.image_tag
  deployment_environment = "prod"

  extra_resource_attributes = {
    "team"   = "sre"
    "region" = "us-central1"
  }
}

module "fleet" {
  source = "github.com/fleetdm/fleet-terraform//gcp?ref=main"
  # ... other inputs ...

  fleet_config = merge(var.fleet_config, {
    extra_env_vars = merge(
      coalesce(var.fleet_config.extra_env_vars, {}),
      module.fleet_otel.fleet_extra_environment_variables.universal,
    )
  })

  service_only_env_vars = module.fleet_otel.fleet_extra_environment_variables.service_only

  sidecar_containers = [
    # Pick one of the example sidecar definitions below.
  ]
}
```

The split between `universal` and `service_only` env vars exists because Fleet's migration job (a Cloud Run Job, not a Service) runs without sidecars. The `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` var would point to a non-existent listener during migrations, causing exporter retry noise in the job logs. Wire `universal` into `extra_env_vars` (visible to both) and `service_only` into `service_only_env_vars` (Service only).

## Sidecar examples

Each example is a single object you drop into `module.fleet.sidecar_containers = [ ... ]`. Cloud Run requires:

1. Every sidecar declared in another container's `depends_on_container` must have its own `startup_probe`. The probe targets the OTLP gRPC port — once it accepts connections, the collector is ready.
2. Only one container per service may own the ingress port. Set `ports = { name = "", container_port = 0 }` on sidecars to opt out (sentinel honored by the cloud-run v2 module once [PR #450](https://github.com/GoogleCloudPlatform/terraform-google-cloud-run/pull/450) lands).

### OpenTelemetry Collector (contrib) — vendor-neutral

```hcl
sidecar_containers = [
  {
    container_name  = "otel-collector"
    container_image = "otel/opentelemetry-collector-contrib:latest"
    container_args  = ["--config=/etc/otelcol/config.yaml"]

    # You need to mount a config.yaml. Store it as a Secret Manager secret
    # and mount via volume_mounts. See addons/gcp/otel-sidecar/examples/
    # for a config that exports to Datadog, Honeycomb, or Grafana Cloud.
    volume_mounts = [{
      name       = "otel-config"
      mount_path = "/etc/otelcol"
    }]

    resources = {
      limits = { cpu = "500m", memory = "256Mi" }
    }
    ports = { name = "", container_port = 0 }
    startup_probe = {
      tcp_socket            = { port = 4317 }
      initial_delay_seconds = 5
      period_seconds        = 5
      timeout_seconds       = 2
      failure_threshold     = 30
    }
  }
]
```

### Datadog DDOT collector — Datadog backend

DDOT is the Datadog Agent in OTel-collector mode (`DD_OTELCOLLECTOR_ENABLED=true`). Documented for Linux, Kubernetes, and EKS Fargate; the Cloud Run install path isn't covered by Datadog docs but works in practice (verified production usage shipping all three signal types to us5).

Use `agent:latest-full`, not `agent:latest` — the `-full` variant bundles the DDOT subprocess.

```hcl
sidecar_containers = [
  {
    container_name  = "datadog-agent"
    container_image = "gcr.io/datadoghq/agent:latest-full"

    env_vars = {
      DD_SITE                  = "us5.datadoghq.com"  # or datadoghq.com, datadoghq.eu, etc.
      DD_SERVICE               = "fleet"
      DD_ENV                   = "prod"
      DD_VERSION               = "v4.85.0"
      DD_OTELCOLLECTOR_ENABLED = "true"
      DD_LOGS_ENABLED          = "true"
      DD_HOSTNAME              = "fleet-api-cloudrun"  # Cloud Run instances are ephemeral; pin to a logical hostname
    }
    env_secret_vars = {
      DD_API_KEY = {
        secret  = google_secret_manager_secret.datadog_api_key.secret_id
        version = "latest"
      }
    }

    resources = {
      limits = { cpu = "1", memory = "512Mi" }
    }
    ports = { name = "", container_port = 0 }
    startup_probe = {
      tcp_socket            = { port = 4317 }
      initial_delay_seconds = 5
      period_seconds        = 5
      timeout_seconds       = 2
      failure_threshold     = 30
    }
  }
]
```

Set `enable_otel_logs = false` on this addon if you're using `gcr.io/datadoghq/serverless-init` instead — its OTLP logs pipeline is broken ([datadog-agent#34097](https://github.com/DataDog/datadog-agent/issues/34097)). DDOT's is fine.

### Grafana Alloy — Grafana Cloud / self-hosted Grafana stack

Similar pattern: image is `grafana/alloy:latest`, args point at a config file mounted via `volume_mounts`. Config follows the Alloy "river" config format with an `otelcol.receiver.otlp` block.

## Notes

- Fleet sets `OTEL_SERVICE_NAME=fleet` internally via `semconv.ServiceName("fleet")`. We set it again in the env var so callers can override.
- The Go OTel SDK defaults to TLS for OTLP gRPC. Talking plaintext to a localhost sidecar requires `OTEL_EXPORTER_OTLP_INSECURE=true` (this addon sets it).
- `FLEET_LOGGING_OTEL_LOGS_ENABLED=true` requires `FLEET_LOGGING_TRACING_ENABLED=true` (Fleet validates this on startup — see `cmd/fleet/serve.go`).
- The migration job runs only once per `image_tag` change. Even without the env-var split, the noise window is brief, but the split is correct hygiene.
