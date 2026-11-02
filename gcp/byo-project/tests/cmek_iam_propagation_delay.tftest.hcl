// Plan-only checks for the per-service CMEK IAM propagation wait
// (cmek-readiness.tf): which configurations create time_sleep, its duration,
// its replacement triggers, and input validation. Every provider is mocked,
// so no GCP credentials are needed, nothing is created and nothing sleeps.
// Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Apply-time ordering (grants -> wait -> Cloud SQL, Memorystore, Cloud Run
// service + migration job, managed secrets) comes from depends_on /
// module_depends_on and is visible in `terraform graph`; a mocked plan cannot
// prove it.

mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b", "us-central1-c"]
    }
  }
}
mock_provider "google-beta" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "terracurl" {}
mock_provider "time" {}

// Stable project number for the service-agent emails.
override_data {
  target = data.google_project.cmek
  values = {
    number = "123456789012"
  }
}

variables {
  project_id      = "fleet-test-project"
  dns_zone_name   = "example.com."
  dns_record_name = "fleet.example.com."
  fleet_config = {
    image_tag              = "fleetdm/fleet:v4.93.0"
    fleet_cpu              = "1000m"
    fleet_memory           = "4096Mi"
    debug_logging          = false
    min_instance_count     = 1
    max_instance_count     = 5
    exec_migration         = true
    use_h2c                = false
    extra_env_vars         = {}
    extra_secret_env_vars  = {}
    installers_bucket_name = "fleet-test-installers"
  }
}

// ---------------------------------------------------------------------------
// No per-service consumer: no time_sleep, no delay.
// ---------------------------------------------------------------------------
run "defaults_have_no_wait" {
  command = plan

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 120
    error_message = "cmek_iam_propagation_delay_seconds must default to 120."
  }

  assert {
    condition     = length(time_sleep.cmek_iam_propagation) == 0 && length(local.cmek_iam_propagation_triggers) == 0
    error_message = "Default config must not create the CMEK IAM propagation wait."
  }
}

run "legacy_gcs_only_has_no_wait" {
  command = plan

  variables {
    cmek = {
      enable         = true
      kms_key_ring   = "fleet-ring"
      kms_crypto_key = "fleet-key"
    }
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gcs_cmek) == 1
    error_message = "Legacy GCS CMEK must still grant the GCS service agent."
  }

  assert {
    condition     = length(time_sleep.cmek_iam_propagation) == 0
    error_message = "Legacy GCS-only CMEK must not create the CMEK IAM propagation wait."
  }
}

// The delay setting alone never creates a wait.
run "custom_delay_without_consumers_has_no_wait" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = 600
  }

  assert {
    condition     = length(time_sleep.cmek_iam_propagation) == 0
    error_message = "A delay without per-service consumers must not create the wait."
  }
}

// ---------------------------------------------------------------------------
// Each consumer alone creates exactly one wait, triggered by its own grant.
// ---------------------------------------------------------------------------
run "cloud_sql_alone_waits" {
  command = plan

  variables {
    cmek = { cloud_sql = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" } }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].create_duration == "120s" &&
      time_sleep.cmek_iam_propagation[0].destroy_duration == null
    )
    error_message = "Cloud SQL CMEK must create one 120s create-time wait."
  }

  assert {
    condition = time_sleep.cmek_iam_propagation[0].triggers == tomap({
      cloud_sql = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-cloud-sql.iam.gserviceaccount.com"
    })
    error_message = "Wait must be triggered by the Cloud SQL grant's key, role and member only."
  }
}

run "redis_alone_waits" {
  command = plan

  variables {
    cmek = { redis = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" } }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].create_duration == "120s" &&
      time_sleep.cmek_iam_propagation[0].triggers == tomap({
        redis = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@cloud-redis.iam.gserviceaccount.com"
      })
    )
    error_message = "Memorystore CMEK must create one 120s wait triggered by the Redis grant."
  }
}

run "cloud_run_alone_waits" {
  command = plan

  variables {
    cmek = { cloud_run = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" } }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].create_duration == "120s" &&
      time_sleep.cmek_iam_propagation[0].triggers == tomap({
        cloud_run = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"
      })
    )
    error_message = "Cloud Run CMEK must create one 120s wait triggered by the Cloud Run grant."
  }
}

run "secret_manager_alone_waits" {
  command = plan

  variables {
    cmek = { secret_manager = { kms_key_id = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" } }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].create_duration == "120s" &&
      time_sleep.cmek_iam_propagation[0].triggers == tomap({
        "secret_manager.global" = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-secretmanager.iam.gserviceaccount.com"
      })
    )
    error_message = "Secret Manager CMEK must create one 120s wait triggered by the global secret grant."
  }
}

run "secret_manager_replicas_each_trigger" {
  command = plan

  variables {
    replicate_secrets = ["us-central1", "us-east1"]
    cmek = {
      secret_manager = {
        replica_kms_key_ids = {
          us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/secrets"
          us-east1    = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/secrets"
        }
      }
    }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].triggers == tomap({
        "secret_manager.us-central1" = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/secrets|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-secretmanager.iam.gserviceaccount.com"
        "secret_manager.us-east1"    = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/secrets|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-secretmanager.iam.gserviceaccount.com"
      })
    )
    error_message = "Every replica-region grant must be a trigger of the single wait."
  }
}

// ---------------------------------------------------------------------------
// All consumers sharing ONE key: still one wait, one trigger per grant, and
// every trigger is fully known at plan time from configuration (no etag), so
// a shared key's policy etag changing cannot cause perpetual diffs.
// ---------------------------------------------------------------------------
run "all_consumers_shared_key_one_stable_wait" {
  command = plan

  variables {
    cmek = {
      cloud_sql      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared" }
      redis          = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared" }
      cloud_run      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared" }
      secret_manager = { kms_key_id = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" }
    }
  }

  assert {
    condition     = length(time_sleep.cmek_iam_propagation) == 1
    error_message = "All consumers must share a single wait."
  }

  assert {
    condition = time_sleep.cmek_iam_propagation[0].triggers == tomap({
      cloud_sql               = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-cloud-sql.iam.gserviceaccount.com"
      redis                   = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@cloud-redis.iam.gserviceaccount.com"
      cloud_run               = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/shared|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"
      "secret_manager.global" = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets|roles/cloudkms.cryptoKeyEncrypterDecrypter|serviceAccount:service-123456789012@gcp-sa-secretmanager.iam.gserviceaccount.com"
    })
    error_message = "Triggers must be exactly one config-derived (key|role|member) entry per opted-in grant, known at plan time."
  }
}

// ---------------------------------------------------------------------------
// Custom and zero durations.
// ---------------------------------------------------------------------------
run "custom_delay" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = 300
    cmek                               = { redis = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" } }
  }

  assert {
    condition     = time_sleep.cmek_iam_propagation[0].create_duration == "300s"
    error_message = "Custom delay must set the wait duration."
  }
}

run "zero_delay_keeps_ordering_without_waiting" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = 0
    cmek                               = { cloud_run = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" } }
  }

  assert {
    condition = (
      length(time_sleep.cmek_iam_propagation) == 1 &&
      time_sleep.cmek_iam_propagation[0].create_duration == "0s"
    )
    error_message = "Zero delay must keep the (no-op) wait resource with a 0s duration."
  }
}

// nullable = false: an explicit null falls back to the default.
run "null_delay_uses_default" {
  command = plan

  variables {
    cmek_iam_propagation_delay_seconds = null
    cmek                               = { cloud_sql = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" } }
  }

  assert {
    condition     = var.cmek_iam_propagation_delay_seconds == 120 && time_sleep.cmek_iam_propagation[0].create_duration == "120s"
    error_message = "A null delay must fall back to 120 seconds."
  }
}

// ---------------------------------------------------------------------------
// Unknown key IDs (e.g. from a key created in the same apply) stay plannable:
// count uses object presence, never a key ID. The helper module derives every
// key ID from terraform_data.id, which is unknown at plan time.
// ---------------------------------------------------------------------------
run "unknown_key_ids_are_plannable" {
  command = plan

  module {
    source = "./tests/cmek_iam_propagation_delay_unknown_keys"
  }

  // Passing = the plan succeeds (no "count depends on unknown values").
  assert {
    condition     = length(terraform_data.unknown_key_suffix.input) > 0
    error_message = "Helper must build key IDs from an apply-time value."
  }
}

// ---------------------------------------------------------------------------
// Invalid delays are rejected at plan time.
// ---------------------------------------------------------------------------
run "reject_negative_delay" {
  command = plan
  variables {
    cmek_iam_propagation_delay_seconds = -1
  }
  expect_failures = [var.cmek_iam_propagation_delay_seconds]
}

run "reject_fractional_delay" {
  command = plan
  variables {
    cmek_iam_propagation_delay_seconds = 1.5
  }
  expect_failures = [var.cmek_iam_propagation_delay_seconds]
}
