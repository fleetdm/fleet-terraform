// Input validation and migration-disabled mode (plan only, mocked).
mock_provider "google-beta" {}
mock_provider "terracurl" {}
mock_provider "time" {}

variables {
  project_id            = "fictional-proj"
  region                = "us-central1"
  image                 = "fleetdm/fleet:v4.93.0"
  service_account_email = "fleet-run-sa@fictional-proj.iam.gserviceaccount.com"
  vpc_network           = "fleet-network"
  vpc_subnetwork        = "fleet-subnet"
  cpu                   = "1000m"
  memory                = "4096Mi"
  min_instance_count    = 1
  max_instance_count    = 5
  database_identity     = { sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d", database_name = "fleet" }
}

run "memory_floor_4096Mi_rejected_below" {
  command = plan
  variables {
    memory = "2048Mi"
  }
  expect_failures = [var.memory]
}

run "memory_floor_accepts_gi" {
  command = plan
  variables {
    memory = "8Gi"
  }
  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits.memory == "8Gi"
    error_message = "8Gi must pass the floor."
  }
}

run "job_prefix_length_bounded" {
  command = plan
  variables {
    job_name_prefix = "this-prefix-is-far-too-long-for-a-job"
  }
  expect_failures = [var.job_name_prefix]
}

run "migration_disabled_static_zero_cardinality" {
  command = plan
  variables {
    migration_enabled = false
  }
  assert {
    condition = (
      length(terraform_data.identity) == 0 && length(google_cloud_run_v2_job.migration) == 0 &&
      length(terracurl_request.stop) == 0 && length(terracurl_request.restore) == 0 &&
      length(data.terracurl_request.service_live) == 0 &&
      length(data.terracurl_request.executions_live) == 0 &&
      # The restore settlement chain has static cardinality too (no count/
      # for_each decided by an API response).
      length(data.terracurl_request.restore_probe_wait) == 0 &&
      length(time_sleep.restore_settle_1) == 0 && length(data.terracurl_request.restore_probe_1) == 0 &&
      length(time_sleep.restore_settle_2) == 0 && length(data.terracurl_request.restore_probe_2) == 0 &&
      length(time_sleep.restore_settle_3) == 0 &&
      google_cloud_run_v2_service.fleet.scaling[0].scaling_mode == "AUTOMATIC" &&
      google_cloud_run_v2_service.fleet.scaling[0].min_instance_count == 1 &&
      length(google_cloud_run_v2_service.fleet.template[0].annotations) == 0
    )
    error_message = "Disabled migrations: no lifecycle objects, AUTOMATIC/min service."
  }
}
