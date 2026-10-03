# -------------------------------------
# BigQuery
# -------------------------------------

resource "google_bigquery_dataset" "fleet_logs" {
  project    = local.bq_project_id
  dataset_id = var.bq_dataset_id
  location   = "US"

  labels = {
    managed-by = "terraform"
    app        = "fleet"
  }
}

resource "google_bigquery_table" "result_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "result_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "unix_time"
  }

  clustering = ["query_name", "host_identifier"]

  schema = jsonencode([
    { name = "inserted_at",     type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "query_name",      type = "STRING",    mode = "REQUIRED", description = "Osquery query name (name field)" },
    { name = "query_id",        type = "INTEGER",   mode = "NULLABLE", description = "Fleet query ID injected by Fleet when query is known" },
    { name = "host_identifier", type = "STRING",    mode = "REQUIRED", description = "Osquery hostIdentifier" },
    { name = "calendar_time",   type = "STRING",    mode = "NULLABLE", description = "Human-readable calendarTime from osquery" },
    { name = "unix_time",       type = "TIMESTAMP", mode = "NULLABLE", description = "unixTime epoch converted to TIMESTAMP" },
    { name = "action",          type = "STRING",    mode = "NULLABLE", description = "snapshot, added, or removed" },
    { name = "epoch",           type = "INTEGER",   mode = "NULLABLE", description = "Schedule epoch marker" },
    { name = "counter",         type = "INTEGER",   mode = "NULLABLE", description = "Execution counter" },
    { name = "host_uuid",       type = "STRING",    mode = "NULLABLE", description = "decorations.host_uuid extracted for easy filtering" },
    { name = "decorations",     type = "STRING",    mode = "NULLABLE", description = "Full decorations map as JSON string" },
    { name = "row",             type = "STRING",    mode = "REQUIRED", description = "One result row as JSON string (one element from snapshot[], or columns, or one diffResults element)" }
  ])
}

resource "google_bigquery_table" "status_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "status_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "inserted_at"
  }

  clustering = ["severity"]

  schema = jsonencode([
    { name = "inserted_at", type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "severity",    type = "INTEGER",   mode = "REQUIRED", description = "0=INFO, 1=WARNING, 2=ERROR" },
    { name = "filename",    type = "STRING",    mode = "NULLABLE", description = "Source file from osquery agent" },
    { name = "line",        type = "INTEGER",   mode = "NULLABLE", description = "Line number in source file" },
    { name = "message",     type = "STRING",    mode = "NULLABLE", description = "Log message" },
    { name = "version",     type = "STRING",    mode = "NULLABLE", description = "Osquery agent version" },
    { name = "host_uuid",   type = "STRING",    mode = "NULLABLE", description = "decorations.host_uuid" },
    { name = "decorations", type = "STRING",    mode = "NULLABLE", description = "Full decorations map as JSON string" }
  ])
}

resource "google_bigquery_table" "audit_logs" {
  project             = local.bq_project_id
  dataset_id          = google_bigquery_dataset.fleet_logs.dataset_id
  table_id            = "audit_logs"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  clustering = ["type", "actor_email"]

  schema = jsonencode([
    { name = "inserted_at",     type = "TIMESTAMP", mode = "REQUIRED", description = "Time the Cloud Run service received the message" },
    { name = "id",              type = "INTEGER",   mode = "NULLABLE", description = "Fleet activity ID" },
    { name = "uuid",            type = "STRING",    mode = "NULLABLE", description = "Fleet activity UUID" },
    { name = "created_at",      type = "TIMESTAMP", mode = "NULLABLE", description = "Fleet activity created_at timestamp" },
    { name = "type",            type = "STRING",    mode = "REQUIRED", description = "Activity type (e.g. created_user, installed_software)" },
    { name = "actor_id",        type = "INTEGER",   mode = "NULLABLE", description = "Fleet user ID (null for automation)" },
    { name = "actor_full_name", type = "STRING",    mode = "NULLABLE", description = "Actor full name" },
    { name = "actor_email",     type = "STRING",    mode = "NULLABLE", description = "Actor email" },
    { name = "actor_api_only",  type = "BOOLEAN",   mode = "NULLABLE", description = "True if actor is an API-only user" },
    { name = "fleet_initiated", type = "BOOLEAN",   mode = "NULLABLE", description = "True if triggered by Fleet automation" },
    { name = "details",         type = "STRING",    mode = "NULLABLE", description = "Full details blob as JSON string — varies by type" }
  ])
}

# -------------------------------------
# Cloud Run — ingest service
# -------------------------------------

resource "google_cloud_run_v2_service" "ingest" {
  project             = var.project_id
  name                = "fleet-pubsub-bq"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.ingest_sa.email

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      env {
        name  = "BQ_PROJECT_ID"
        value = local.bq_project_id
      }
      env {
        name  = "BQ_DATASET_ID"
        value = var.bq_dataset_id
      }
      env {
        name  = "RESULT_SUBSCRIPTION"
        value = local.result_subscription_name
      }
      env {
        name  = "STATUS_SUBSCRIPTION"
        value = local.status_subscription_name
      }
      env {
        name  = "AUDIT_SUBSCRIPTION"
        value = local.audit_subscription_name
      }
    }
  }
}

# Grant the PubSub invoker SA permission to invoke the Cloud Run service.
resource "google_cloud_run_v2_service_iam_member" "pubsub_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.ingest.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_invoker_sa.email}"
}

# -------------------------------------
# PubSub push subscriptions
# -------------------------------------

resource "google_pubsub_subscription" "result" {
  project = var.project_id
  name    = local.result_subscription_name
  topic   = var.result_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}

resource "google_pubsub_subscription" "status" {
  project = var.project_id
  name    = local.status_subscription_name
  topic   = var.status_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}

resource "google_pubsub_subscription" "audit" {
  project = var.project_id
  name    = local.audit_subscription_name
  topic   = var.audit_topic_name

  ack_deadline_seconds = 600

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ingest.uri}/ingest"

    oidc_token {
      service_account_email = google_service_account.pubsub_invoker_sa.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.pubsub_invoker]
}
