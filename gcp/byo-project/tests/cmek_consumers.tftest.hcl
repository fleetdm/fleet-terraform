// Plan-only checks for the opt-in per-service CMEK consumers (cmek.cloud_sql,
// cmek.redis, cmek.cloud_run, cmek.secret_manager) and for the legacy
// GCS-only cmek.enable path staying unchanged. Every provider is mocked, so no
// GCP credentials are needed and nothing is created. Run from gcp/byo-project:
//   terraform init -backend=false && terraform test
//
// Registry modules (Cloud SQL, Memorystore, Cloud Run service) cannot be
// inspected from a test, so their CMEK inputs are checked through the locals
// passed to them (database.tf, cache.tf, cloud_run.tf). Resources declared in
// this module (grants, service identities, secrets, migration job) are checked
// directly. Apply-time ordering comes from depends_on and is visible in
// `terraform graph`.

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

// Stable project number for the service-agent emails (only read when a
// per-service consumer is opted in).
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
  // Non-empty bucket name keeps the plan valid against the minimum (6.35)
  // google provider schema as well as the current one.
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
// Defaults: no new reads, identities or grants; everything Google-managed.
// ---------------------------------------------------------------------------
run "defaults_create_no_cmek_resources" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  assert {
    condition = (
      length(google_project_service.cloudkms) == 0 &&
      length(data.google_project.cmek) == 0 &&
      length(google_project_service_identity.cloud_sql) == 0 &&
      length(google_project_service_identity.secret_manager) == 0 &&
      length(google_kms_crypto_key_iam_member.gcs_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_sql_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.redis_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_run_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.secret_manager_cmek) == 0
    )
    error_message = "Default config must not enable the KMS API, read the project, create service identities or grant any KMS access."
  }

  assert {
    condition = (
      local.cmek_cloud_sql_key_id == null &&
      local.cmek_redis_key_id == null &&
      local.cmek_cloud_run_key_id == null
    )
    error_message = "Default config must pass null keys to Cloud SQL, Memorystore and Cloud Run (Google-managed)."
  }

  assert {
    condition     = google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].encryption_key == null
    error_message = "Default migration job must stay Google-managed."
  }

  assert {
    condition = alltrue([
      for s in [
        google_secret_manager_secret.database_password,
        google_secret_manager_secret.hmac_secret,
        google_secret_manager_secret.private_key[0],
      ] : length(s.replication[0].auto) == 1 && length(s.replication[0].auto[0].customer_managed_encryption) == 0
    ])
    error_message = "Default managed secrets must keep automatic replication with Google-managed encryption."
  }

  assert {
    condition     = length(google_storage_bucket.software_installers.encryption) == 0
    error_message = "Default installers bucket must stay Google-managed."
  }
}

// ---------------------------------------------------------------------------
// Legacy cmek.enable = true: GCS only, exactly as before.
// ---------------------------------------------------------------------------
run "legacy_enable_is_gcs_only" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    cmek = {
      enable         = true
      kms_key_ring   = "fleet-ring"
      kms_crypto_key = "fleet-key"
    }
  }

  assert {
    condition     = length(google_project_service.cloudkms) == 1 && length(google_kms_crypto_key_iam_member.gcs_cmek) == 1
    error_message = "Legacy enable must keep enabling the KMS API and granting the GCS service agent."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gcs_cmek[0].crypto_key_id == "projects/fleet-test-project/locations/us/keyRings/fleet-ring/cryptoKeys/fleet-key"
    error_message = "Legacy key must still resolve at var.location."
  }

  assert {
    condition = (
      length(data.google_project.cmek) == 0 &&
      length(google_project_service_identity.cloud_sql) == 0 &&
      length(google_project_service_identity.secret_manager) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_sql_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.redis_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_run_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.secret_manager_cmek) == 0
    )
    error_message = "Legacy enable must not opt in any non-GCS consumer."
  }

  assert {
    condition = (
      local.cmek_cloud_sql_key_id == null &&
      local.cmek_redis_key_id == null &&
      local.cmek_cloud_run_key_id == null &&
      google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].encryption_key == null &&
      length(google_secret_manager_secret.database_password.replication[0].auto[0].customer_managed_encryption) == 0
    )
    error_message = "Legacy enable must leave Cloud SQL, Memorystore, Cloud Run and secrets Google-managed."
  }
}

// ---------------------------------------------------------------------------
// All new consumers, automatic secret replication, legacy GCS CMEK off.
// ---------------------------------------------------------------------------
run "all_consumers_automatic_replication_gcs_off" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    cmek = {
      cloud_sql      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" }
      redis          = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" }
      cloud_run      = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" }
      secret_manager = { kms_key_id = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" }
    }
  }

  assert {
    condition     = length(google_project_service.cloudkms) == 1 && length(data.google_project.cmek) == 1
    error_message = "Any per-service consumer must enable the KMS API and read the project number."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gcs_cmek) == 0 && length(google_storage_bucket.software_installers.encryption) == 0
    error_message = "New consumers must not turn on the legacy GCS CMEK path."
  }

  assert {
    condition = (
      google_project_service_identity.cloud_sql[0].service == "sqladmin.googleapis.com" &&
      google_project_service_identity.secret_manager[0].service == "secretmanager.googleapis.com" &&
      google_project_service_identity.cloud_sql[0].project == "fleet-test-project"
    )
    error_message = "Cloud SQL and Secret Manager service identities must be provisioned in the Fleet project."
  }

  assert {
    condition = (
      google_kms_crypto_key_iam_member.cloud_sql_cmek[0].crypto_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" &&
      google_kms_crypto_key_iam_member.cloud_sql_cmek[0].member == "serviceAccount:service-123456789012@gcp-sa-cloud-sql.iam.gserviceaccount.com" &&
      google_kms_crypto_key_iam_member.cloud_sql_cmek[0].role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    )
    error_message = "Cloud SQL key must be granted to the Cloud SQL service agent."
  }

  assert {
    condition = (
      google_kms_crypto_key_iam_member.redis_cmek[0].crypto_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" &&
      google_kms_crypto_key_iam_member.redis_cmek[0].member == "serviceAccount:service-123456789012@cloud-redis.iam.gserviceaccount.com"
    )
    error_message = "Redis key must be granted to the Memorystore service agent."
  }

  assert {
    condition = (
      google_kms_crypto_key_iam_member.cloud_run_cmek[0].crypto_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run" &&
      google_kms_crypto_key_iam_member.cloud_run_cmek[0].member == "serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"
    )
    error_message = "Cloud Run key must be granted to the Cloud Run service agent."
  }

  assert {
    condition = (
      keys(google_kms_crypto_key_iam_member.secret_manager_cmek) == ["global"] &&
      google_kms_crypto_key_iam_member.secret_manager_cmek["global"].crypto_key_id == "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" &&
      google_kms_crypto_key_iam_member.secret_manager_cmek["global"].member == "serviceAccount:service-123456789012@gcp-sa-secretmanager.iam.gserviceaccount.com"
    )
    error_message = "Global secret key must be granted to the Secret Manager service agent."
  }

  assert {
    condition = (
      local.cmek_cloud_sql_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/sql" &&
      local.cmek_redis_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/redis" &&
      local.cmek_cloud_run_key_id == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run"
    )
    error_message = "Cloud SQL, Memorystore and Cloud Run must receive their caller-supplied keys."
  }

  assert {
    condition     = google_cloud_run_v2_job.fleet_migration_job.template[0].template[0].encryption_key == "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run"
    error_message = "Migration job must use the Cloud Run key."
  }

  assert {
    condition = alltrue([
      for s in [
        google_secret_manager_secret.database_password,
        google_secret_manager_secret.hmac_secret,
        google_secret_manager_secret.private_key[0],
      ] : s.replication[0].auto[0].customer_managed_encryption[0].kms_key_name == "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets"
    ])
    error_message = "Every Fleet-managed secret must use the global key under automatic replication."
  }
}

// ---------------------------------------------------------------------------
// User-managed replication: one key per replica region.
// ---------------------------------------------------------------------------
run "two_region_secret_replicas_use_regional_keys" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

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
      toset(keys(google_kms_crypto_key_iam_member.secret_manager_cmek)) == toset(["us-central1", "us-east1"]) &&
      google_kms_crypto_key_iam_member.secret_manager_cmek["us-east1"].crypto_key_id == "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/secrets"
    )
    error_message = "Each replica region key must be granted to the Secret Manager service agent."
  }

  assert {
    condition = alltrue([
      for s in [
        google_secret_manager_secret.database_password,
        google_secret_manager_secret.hmac_secret,
        google_secret_manager_secret.private_key[0],
        ] : length(s.replication[0].auto) == 0 && {
        for r in s.replication[0].user_managed[0].replicas :
        r.location => one(r.customer_managed_encryption[*].kms_key_name)
        } == {
        us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/secrets"
        us-east1    = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/secrets"
      }
    ])
    error_message = "Every replica of every Fleet-managed secret must use the key in its own region."
  }

  assert {
    condition = (
      length(google_project_service_identity.cloud_sql) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_sql_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.redis_cmek) == 0 &&
      length(google_kms_crypto_key_iam_member.cloud_run_cmek) == 0
    )
    error_message = "Opting in secrets only must not opt in other consumers."
  }
}

// ---------------------------------------------------------------------------
// External private-key secret stays untouched; managed secrets still encrypted.
// ---------------------------------------------------------------------------
run "external_private_key_untouched" {
  command = plan

  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }

  variables {
    fleet_config = {
      image_tag                       = "fleetdm/fleet:v4.93.0"
      fleet_cpu                       = "1000m"
      fleet_memory                    = "4096Mi"
      debug_logging                   = false
      fleet_server_private_key_secret = "existing-fleet-private-key"
      min_instance_count              = 1
      max_instance_count              = 5
      exec_migration                  = true
      use_h2c                         = false
      extra_env_vars                  = {}
      extra_secret_env_vars           = {}
      installers_bucket_name          = "fleet-test-installers"
    }
    cmek = {
      secret_manager = { kms_key_id = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" }
    }
  }

  override_data {
    target = data.google_secret_manager_secret.external_private_key[0]
    values = {
      id        = "projects/fleet-test-project/secrets/existing-fleet-private-key"
      secret_id = "existing-fleet-private-key"
    }
  }

  assert {
    condition = (
      length(google_secret_manager_secret.private_key) == 0 &&
      length(google_secret_manager_secret_version.private_key) == 0 &&
      google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access.secret_id == "projects/fleet-test-project/secrets/existing-fleet-private-key"
    )
    error_message = "External private-key secret must be referenced only, never created or re-encrypted."
  }

  assert {
    condition = (
      google_secret_manager_secret.database_password.replication[0].auto[0].customer_managed_encryption[0].kms_key_name == "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets" &&
      google_secret_manager_secret.hmac_secret.replication[0].auto[0].customer_managed_encryption[0].kms_key_name == "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/secrets"
    )
    error_message = "Managed secrets must still be encrypted when the private key is external."
  }
}

// ---------------------------------------------------------------------------
// Invalid inputs are rejected at plan time.
// ---------------------------------------------------------------------------
run "reject_cloud_sql_key_in_wrong_region" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { cloud_sql = { kms_key_id = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/sql" } }
  }
  expect_failures = [var.cmek]
}

run "reject_redis_short_key_name" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { redis = { kms_key_id = "redis-key" } }
  }
  expect_failures = [var.cmek]
}

run "reject_cloud_run_null_key" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { cloud_run = { kms_key_id = null } }
  }
  expect_failures = [var.cmek]
}

run "reject_cloud_run_key_ring_only" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { cloud_run = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r" } }
  }
  expect_failures = [var.cmek]
}

run "reject_automatic_secret_regional_key" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { secret_manager = { kms_key_id = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s" } }
  }
  expect_failures = [var.cmek]
}

run "reject_automatic_secret_missing_key" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = { secret_manager = {} }
  }
  expect_failures = [var.cmek]
}

run "reject_automatic_secret_with_replica_map" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    cmek = {
      secret_manager = {
        kms_key_id          = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/s"
        replica_kms_key_ids = { us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s" }
      }
    }
  }
  expect_failures = [var.cmek]
}

run "reject_user_managed_secret_with_global_key" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    replicate_secrets = ["us-central1"]
    cmek = {
      secret_manager = {
        kms_key_id          = "projects/kms-proj/locations/global/keyRings/g/cryptoKeys/s"
        replica_kms_key_ids = { us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s" }
      }
    }
  }
  expect_failures = [var.cmek]
}

run "reject_user_managed_secret_missing_region" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    replicate_secrets = ["us-central1", "us-east1"]
    cmek = {
      secret_manager = {
        replica_kms_key_ids = { us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s" }
      }
    }
  }
  expect_failures = [var.cmek]
}

run "reject_user_managed_secret_extra_region" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    replicate_secrets = ["us-central1"]
    cmek = {
      secret_manager = {
        replica_kms_key_ids = {
          us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s"
          us-east1    = "projects/kms-proj/locations/us-east1/keyRings/r/cryptoKeys/s"
        }
      }
    }
  }
  expect_failures = [var.cmek]
}

run "reject_replica_key_in_wrong_region" {
  command = plan
  providers = {
    google      = google
    google-beta = google-beta
    null        = null
    random      = random
    terracurl   = terracurl
  }
  variables {
    replicate_secrets = ["us-central1", "us-east1"]
    cmek = {
      secret_manager = {
        replica_kms_key_ids = {
          us-central1 = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s"
          us-east1    = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/s"
        }
      }
    }
  }
  expect_failures = [var.cmek]
}
