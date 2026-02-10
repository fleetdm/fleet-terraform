<!-- BEGIN_TF_DOCS -->
# Fleet CloudWatch Log Sharing GCP Target

This module creates the Google Cloud destination side for Fleet CloudWatch log sharing:

- Pub/Sub topic for log ingestion from the AWS bridge Lambda.
- Service account (and optional key) used by the AWS bridge Lambda to publish.
- Cloud Storage bucket destination.
- Pub/Sub subscription that streams topic data into Cloud Storage.

This is the Google Cloud equivalent of an AWS target account module that ends in `S3`.

## Usage

```hcl
provider "google" {
  project = "customer-observability-prod"
  region  = "us-central1"
}

module "fleet_log_sharing_target_gcp" {
  source = "github.com/fleetdm/fleet-terraform//addons/byo-cloudwatch-log-sharing/target-account-gcp?depth=1&ref=tf-mod-addon-byo-cloudwatch-log-sharing-v1.0.0"

  # Optional. If omitted, module uses provider "google" project.
  # project_id = "customer-observability-prod"

  service_account = {
    # Optional. If omitted, defaults to "fleet-cwl-pubsub-publisher".
    account_id = "fleet-cwl-pubsub-publisher"
  }

  pubsub = {
    topic_name        = "fleet-cloudwatch-logs"
    subscription_name = "fleet-cloudwatch-logs-to-gcs"
  }

  gcs = {
    bucket_name = "customer-fleet-cloudwatch-logs"
    location    = "US"
  }

  delivery = {
    filename_prefix = "fleet/logs/"
    filename_suffix = ".jsonl"
    max_duration    = "300s"
    max_bytes       = 10485760
  }
}

output "fleet_log_sharing_target_gcp" {
  value = module.fleet_log_sharing_target_gcp
}
```

### Cross-Organization Hand-off to AWS Bridge Team

Share these values out-of-band with the team that manages the AWS `pubsub-bridge` module:

- `module.fleet_log_sharing_target_gcp.bridge.project_id`
- `module.fleet_log_sharing_target_gcp.bridge.topic_id`
- `module.fleet_log_sharing_target_gcp.publisher_credentials_json`

The bridge team stores `publisher_credentials_json` in AWS Secrets Manager and passes the secret ARN into:

- `addons/byo-cloudwatch-log-sharing/pubsub-bridge`

## Test Publisher Script

A helper script is included to publish validation messages directly to the Pub/Sub topic:

- `scripts/publish_pubsub_test.sh`

Example using built-in default messages:

```bash
./scripts/publish_pubsub_test.sh \
  --project-id customer-observability-prod \
  --topic-id fleet-cloudwatch-logs \
  --service-account-key-file ./service-account.json \
  --debug
```

Example using custom data:

```bash
./scripts/publish_pubsub_test.sh \
  --project-id customer-observability-prod \
  --topic-id fleet-cloudwatch-logs \
  --service-account-key-file ./service-account.json \
  --data-file ./messages.ndjson
```

`messages.ndjson` should contain one message per line.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.7 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.35.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.35.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_pubsub_subscription.gcs_sink](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_topic.fleet_logs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_service_account.publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_key.publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_key) | resource |
| [google_storage_bucket.fleet_logs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.pubsub_bucket_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_bucket_iam_member.pubsub_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_client_config.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_project.target](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_delivery"></a> [delivery](#input\_delivery) | Pub/Sub Cloud Storage subscription delivery settings. | <pre>object({<br/>    filename_prefix = optional(string, "fleet-cloudwatch-logs/")<br/>    filename_suffix = optional(string, ".jsonl")<br/>    max_duration    = optional(string, "300s")<br/>    max_bytes       = optional(number, 10485760)<br/>  })</pre> | `{}` | no |
| <a name="input_gcs"></a> [gcs](#input\_gcs) | Google Cloud Storage destination for delivered Pub/Sub log files. | <pre>object({<br/>    bucket_name   = string<br/>    location      = optional(string, "US")<br/>    storage_class = optional(string, "STANDARD")<br/>    force_destroy = optional(bool, false)<br/>  })</pre> | n/a | yes |
| <a name="input_labels"></a> [labels](#input\_labels) | Labels to apply to resources that support labels. | `map(string)` | `{}` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | Optional GCP project ID where resources will be created. If omitted, the module uses the active Google provider project. | `string` | `""` | no |
| <a name="input_pubsub"></a> [pubsub](#input\_pubsub) | Pub/Sub topic and subscription settings for incoming Fleet log events. | <pre>object({<br/>    topic_name                 = optional(string, "fleet-cloudwatch-logs")<br/>    subscription_name          = optional(string, "fleet-cloudwatch-logs-to-gcs")<br/>    ack_deadline_seconds       = optional(number, 20)<br/>    message_retention_duration = optional(string, "604800s")<br/>  })</pre> | `{}` | no |
| <a name="input_service_account"></a> [service\_account](#input\_service\_account) | Service account used by the AWS bridge Lambda to publish to Pub/Sub. If account\_id is omitted, defaults to fleet-cwl-pubsub-publisher. | <pre>object({<br/>    account_id   = optional(string, "")<br/>    display_name = optional(string, "Fleet CloudWatch Pub/Sub Publisher")<br/>    description  = optional(string, "Publishes Fleet CloudWatch log events to a customer-managed Pub/Sub topic")<br/>    create_key   = optional(bool, true)<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bridge"></a> [bridge](#output\_bridge) | Values to share with the AWS bridge module configuration. |
| <a name="output_publisher_credentials_json"></a> [publisher\_credentials\_json](#output\_publisher\_credentials\_json) | Sensitive Google service-account credentials JSON to store in AWS Secrets Manager for the bridge Lambda. |
| <a name="output_publisher_service_account"></a> [publisher\_service\_account](#output\_publisher\_service\_account) | Publisher service-account details used by the AWS Lambda bridge. |
| <a name="output_pubsub"></a> [pubsub](#output\_pubsub) | Pub/Sub resource details for the log intake topic and GCS sink subscription. |
| <a name="output_storage"></a> [storage](#output\_storage) | Google Cloud Storage destination details. |
<!-- END_TF_DOCS -->