// Mocked plan/apply scenarios for the provider-only lifecycle module.
// (Initially generated with a throwaway script; edit directly.)
//
// These runs exercise Terraform-side logic only: identity/attempt keys,
// declared scaling, request bodies, token suppression, retry naming and the
// pre/postcondition gates. Mock providers do NOT prove what real Cloud Run or
// the real google-beta provider do (LRO waiting, Ready under MANUAL/0, `fields`
// partial responses, etc.). See the loopback-fake integration harness for the
// real-provider checks; neither proves real Cloud Run behaviour.
//
// Runs share one state and are ordered: each run continues from the previous.
// data.terracurl_request.restore_verify is overridden with a restored AND
// settled view in the runs that restore (runs 13-17 cover desired-only /
// unsettled read-backs); a restore LRO that completes with an error and the
// pending/failed control-plane variants are exercised with the real providers
// in lifecycle-tests/integration (S13, S15). The API-reported container image
// is varied (digest, alias, omitted) to show it is never consulted.
//
// MOCK LIMITATION: mock providers only know the JSON schema, not ForceNew /
// RequiresReplace, and an overridden terraform_data loses its built-in
// triggers_replace semantics. Where the real providers would plan a
// replacement (new identity => new job name => new attempt-keyed requests),
// the run lists those replacements in plan_options.replace. The real
// replacement planning is exercised by lifecycle-tests/integration (real
// terraform_data, google-beta and terracurl against a loopback fake API).

mock_provider "google-beta" {
  mock_data "google_client_config" {
    defaults = { access_token = "fake-token-not-a-credential" }
  }
  mock_resource "google_cloud_run_v2_job" {
    defaults = {
      uid                = "job-uid-default"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      terminal_condition      = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
      latest_ready_revision   = "fleet-api-00009"
      latest_created_revision = "fleet-api-00009"
      reconciling             = false
    }
  }
}

mock_provider "terracurl" {
  mock_data "terracurl_request" {
    defaults = { status_code = "404", response = "{}" }
  }
  mock_resource "terracurl_request" {
    defaults = {
      status_code = "200"
      response    = "{\"name\":\"projects/fictional-proj/locations/us-central1/operations/op-fake\",\"done\":false}"
    }
  }
}

mock_provider "time" {}

// Execution inventory (GET jobs/-/executions): by default a valid 200 list of
// settled/unrelated executions, so the earlier-migration guard passes. Runs
// that exercise the guard override it.
override_data {
  target = data.terracurl_request.executions_live[0]
  values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-000000000000/executions/fleet-migrate-000000000000-r1\",\"job\":\"fleet-migrate-000000000000\",\"completionTime\":\"2026-01-01T00:00:00Z\"},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/nightly-report/executions/nightly-report-x\",\"job\":\"nightly-report\",\"runningCount\":1}]}" }
}

variables {
  project_id            = "fictional-proj"
  region                = "us-central1"
  image                 = "fleetdm/fleet:v4.93.0"
  service_account_email = "fleet-run-sa@fictional-proj.iam.gserviceaccount.com"
  vpc_network           = "projects/fictional-proj/global/networks/fleet-network"
  vpc_subnetwork        = "fleet-subnet"
  cpu                   = "1000m"
  memory                = "4096Mi"
  min_instance_count    = 1
  max_instance_count    = 5
  env                   = { FLEET_LICENSE_KEY = "fake-license-not-real", FLEET_MYSQL_DATABASE = "fleet" }
  secret_env            = { FLEET_MYSQL_PASSWORD = { secret = "fleet-db-password", version = "latest" } }
  database_identity     = { sql_connection_name = "fictional-proj:us-central1:fleet-mysql-0a1b2c3d", database_name = "fleet" }
}

// 1. Fresh deployment: service absent (404). Stop is a PATCH that 404s,
//    drain is skipped, one job with a token, service created MANUAL/0 with the
//    attempt annotation, restore sets AUTOMATIC/min + marker = identity.
run "fresh_deploy" {
  command = apply
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"3\",\"observedGeneration\":\"3\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-1\"},\"containers\":[{\"image\":\"fleetdm/fleet:v4.93.0\"}]}}" }
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "11111111-1111-4111-8111-111111111111" }
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-1"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_resource {
    target = terracurl_request.stop[0]
    values = { status_code = "404", response = "{}" }
  }

  assert {
    condition     = output.declared_scaling_mode == "MANUAL" && output.migration_proven == false
    error_message = "Fresh deployment must be declared MANUAL until restored."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.fleet.scaling[0].scaling_mode == "MANUAL" &&
      google_cloud_run_v2_service.fleet.scaling[0].manual_instance_count == 0 &&
      google_cloud_run_v2_service.fleet.scaling[0].min_instance_count == 0
    )
    error_message = "Service must be created MANUAL/0 (staged)."
  }
  assert {
    condition = (
      terracurl_request.stop[0].method == "PATCH" &&
      jsondecode(terracurl_request.stop[0].request_body).scaling == { scalingMode = "MANUAL", manualInstanceCount = 0, minInstanceCount = 0 } &&
      jsondecode(terracurl_request.stop[0].request_body).traffic == [{ type = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", percent = 100 }] &&
      strcontains(terracurl_request.stop[0].url, "updateMask=scaling,traffic") &&
      strcontains(terracurl_request.stop[0].url, "fields=") &&
      terracurl_request.stop[0].destroy_skip == true &&
      terracurl_request.stop[0].response_codes == tolist(["200", "404"])
    )
    error_message = "Stop must PATCH scaling MANUAL/0 and LATEST/100 untagged traffic, metadata-only, 200/404 only, destroy_skip."
  }
  assert {
    condition     = time_sleep.drain[0].create_duration == "0s"
    error_message = "Fresh deployment (stop 404) must not wait for a drain."
  }
  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].name == "fleet-migrate-111111111111" &&
      can(regex("^r[0-9]{12}$", google_cloud_run_v2_job.migration[0].run_execution_token)) &&
      length(google_cloud_run_v2_job.migration[0].name) + length(google_cloud_run_v2_job.migration[0].run_execution_token) < 63 &&
      google_cloud_run_v2_job.migration[0].labels["fleetdm-lifecycle-identity"] == "111111111111"
    )
    error_message = "Job name/token/label contract."
  }
  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].template[0].task_count == 1 &&
      google_cloud_run_v2_job.migration[0].template[0].parallelism == 1 &&
      google_cloud_run_v2_job.migration[0].template[0].template[0].max_retries == 0 &&
      google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].image == "fleetdm/fleet:v4.93.0" &&
      google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].args == tolist(["prepare", "db", "--no-prompt=true"]) &&
      google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].resources[0].limits.memory == "4096Mi"
    )
    error_message = "Job must be single task / single attempt fleet prepare db on the target image with 4096Mi."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-1" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].image == "fleetdm/fleet:v4.93.0" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].resources[0].limits.memory == "4096Mi" &&
      google_cloud_run_v2_service.fleet.template[0].timeout == "300s" &&
      length(google_cloud_run_v2_service.fleet.traffic) == 1 && google_cloud_run_v2_service.fleet.traffic[0].tag == null
    )
    error_message = "Service template must carry the attempt (job UID), target image, 4096Mi, 300s, untagged LATEST traffic."
  }
  assert {
    condition = (
      terracurl_request.restore[0].name == "fleet-lifecycle-restore-job-uid-1" &&
      jsondecode(terracurl_request.restore[0].request_body).scaling == { scalingMode = "AUTOMATIC", minInstanceCount = 1 } &&
      jsondecode(terracurl_request.restore[0].request_body).annotations["fleetdm.com/lifecycle-restored"] == "11111111-1111-4111-8111-111111111111" &&
      strcontains(terracurl_request.restore[0].url, "updateMask=scaling,annotations") &&
      terracurl_request.restore[0].response_codes == tolist(["200"])
    )
    error_message = "Restore must PATCH AUTOMATIC/min and the identity marker, keyed on the job UID."
  }
  assert {
    condition     = !strcontains(terracurl_request.stop[0].request_url_string == null ? "" : terracurl_request.stop[0].request_url_string, "fake-license")
    error_message = "No env in request URLs."
  }
}

// 2. No-op after a restored migration: the live marker proves this identity.
//    Declared AUTOMATIC/min (matches the restored live state), same attempt,
//    same job, same restore key: nothing re-runs, no stop.
run "noop_plan_after_restore" {
  command = plan
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-1\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-111111111111\",\"uid\":\"job-uid-1\",\"labels\":{\"fleetdm-lifecycle-identity\":\"111111111111\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition     = output.migration_proven == true && output.declared_scaling_mode == "AUTOMATIC"
    error_message = "Proven identity must be declared AUTOMATIC."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.fleet.scaling[0].scaling_mode == "AUTOMATIC" &&
      google_cloud_run_v2_service.fleet.scaling[0].min_instance_count == 1 &&
      google_cloud_run_v2_service.fleet.scaling[0].manual_instance_count == null &&
      !contains(keys(google_cloud_run_v2_service.fleet.annotations), "fleetdm.com/lifecycle-restored")
    )
    error_message = "Declared scaling must equal what restore wrote; the marker itself is left to effective_annotations (not declared)."
  }
  assert {
    condition     = output.attempt_id == run.fresh_deploy.attempt_id && output.migration_job_name == run.fresh_deploy.migration_job_name
    error_message = "No-op must keep the attempt and the job."
  }
  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-1"
    error_message = "No-op must not force a new revision."
  }
}

// 3. Same no-op applied: still the same attempt/job/restore objects.
run "noop_apply_after_restore" {
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  command = apply
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-1\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-111111111111\",\"uid\":\"job-uid-1\",\"labels\":{\"fleetdm-lifecycle-identity\":\"111111111111\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition = (
      output.attempt_id == run.fresh_deploy.attempt_id &&
      terracurl_request.stop[0].name == "fleet-lifecycle-stop-${run.fresh_deploy.attempt_id}" &&
      terracurl_request.restore[0].name == "fleet-lifecycle-restore-job-uid-1"
    )
    error_message = "No-op apply must not create a new stop/restore."
  }
}

// 4. Upgrade while an out-of-band traffic tag is still reported: verify
//    refuses (tagged revisions remain reachable under MANUAL/0), so no job is
//    created. (Here the stop PATCH would have removed tags; the fake status
//    shows them still present, e.g. not yet reconciled.)
run "upgrade_blocked_by_traffic_tag" {
  command = apply
  plan_options {
    replace = [
      terraform_data.identity[0],
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.94.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "22222222-2222-4222-8222-222222222222" }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-1\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-111111111111\",\"uid\":\"job-uid-1\",\"labels\":{\"fleetdm-lifecycle-identity\":\"111111111111\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100},{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"fleet-api-00001\",\"tag\":\"canary\"}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100},{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":\"fleet-api-00001\",\"tag\":\"canary\",\"uri\":\"https://canary---fleet-api.example.invalid\"}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\"},\"template\":{\"annotations\":{}}}" }
  }

  expect_failures = [data.terracurl_request.stop_verify]
}

// 5. Same upgrade, now verified stopped: stop + operations.wait + 370s drain,
//    new job (new identity => new name), service staged MANUAL/0 with the new
//    image, restore writes the new marker.
run "upgrade_apply" {
  command = apply
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"22222222-2222-4222-8222-222222222222\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"3\",\"observedGeneration\":\"3\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-2\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:0000000000000000000000000000000000000000000000000000000000000000\"}]}}" }
  }
  plan_options {
    replace = [
      google_cloud_run_v2_job.migration[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.94.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "22222222-2222-4222-8222-222222222222" }
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-2"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"11111111-1111-4111-8111-111111111111\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-1\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-111111111111\",\"uid\":\"job-uid-1\",\"labels\":{\"fleetdm-lifecycle-identity\":\"111111111111\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }

  assert {
    condition     = output.declared_scaling_mode == "MANUAL" && output.migration_proven == false
    error_message = "A new identity must be declared MANUAL until restored, even though the live service was AUTOMATIC."
  }
  assert {
    condition = (
      terracurl_request.stop_wait[0].method == "POST" &&
      strcontains(terracurl_request.stop_wait[0].url, "operations/op-fake:wait") &&
      time_sleep.drain[0].create_duration == "370s"
    )
    error_message = "Existing service: best-effort operations.wait then the 370s bounded drain."
  }
  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].name == "fleet-migrate-222222222222" &&
      google_cloud_run_v2_job.migration[0].template[0].template[0].containers[0].image == "fleetdm/fleet:v4.94.0" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].image == "fleetdm/fleet:v4.94.0" &&
      google_cloud_run_v2_service.fleet.scaling[0].scaling_mode == "MANUAL" &&
      google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-2"
    )
    error_message = "Upgrade must run a new job and deploy the target template while MANUAL/0."
  }
  assert {
    condition     = jsondecode(terracurl_request.restore[0].request_body).annotations["fleetdm.com/lifecycle-restored"] == "22222222-2222-4222-8222-222222222222"
    error_message = "Restore must write the new identity marker."
  }
}

// 6. No-op after the upgrade.
run "upgrade_noop_plan" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.94.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"22222222-2222-4222-8222-222222222222\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-2\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-222222222222\",\"uid\":\"job-uid-2\",\"labels\":{\"fleetdm-lifecycle-identity\":\"222222222222\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition     = output.declared_scaling_mode == "AUTOMATIC" && output.attempt_id == run.upgrade_apply.attempt_id
    error_message = "Upgrade no-op must be AUTOMATIC with the same attempt."
  }
}

// 7. Ordinary config churn (env, CPU, min instances) after a proven
//    migration: no new identity, same attempt and job (the job ignores
//    in-place changes, so run_execution_token is never re-sent); the service
//    takes the change as a normal AUTOMATIC rollout.
run "config_churn_does_not_migrate" {
  command = plan
  variables {
    image              = "fleetdm/fleet:v4.94.0"
    cpu                = "2000m"
    min_instance_count = 2
    env                = { FLEET_LICENSE_KEY = "fake-license-not-real", FLEET_MYSQL_DATABASE = "fleet", FLEET_EXAMPLE = "1" }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"22222222-2222-4222-8222-222222222222\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-2\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-222222222222\",\"uid\":\"job-uid-2\",\"labels\":{\"fleetdm-lifecycle-identity\":\"222222222222\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition = (
      output.migration_identity == run.upgrade_apply.migration_identity &&
      output.attempt_id == run.upgrade_apply.attempt_id &&
      output.migration_job_name == run.upgrade_apply.migration_job_name &&
      output.declared_scaling_mode == "AUTOMATIC" &&
      google_cloud_run_v2_service.fleet.scaling[0].min_instance_count == 2
    )
    error_message = "Config churn must not start a migration."
  }
}

// 8. A migration whose job create LRO "succeeds" but reports a FAILED
//    terminal condition (shape 2): the job postcondition fails the apply, the
//    service is not updated and restore never runs. (Shape 1, an LRO error,
//    is a provider error/taint and can only be shown with the real provider:
//    see the integration harness.)
run "job_failed_shape2" {
  command = apply
  plan_options {
    replace = [
      terraform_data.identity[0],
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.95.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "33333333-3333-4333-8333-333333333333" }
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-3"
      terminal_condition = [{ type = "Ready", state = "CONDITION_FAILED", reason = "fake-prepare-db-exit-1", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"22222222-2222-4222-8222-222222222222\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-2\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-222222222222\",\"uid\":\"job-uid-2\",\"labels\":{\"fleetdm-lifecycle-identity\":\"222222222222\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }

  expect_failures = [google_cloud_run_v2_job.migration]
}

// 9. Plain next apply after the failed job (no taint, no edits): the live
//    FAILED job of this identity yields a new job name => new attempt (stop
//    re-sent, drain, verify) => one fresh execution with current config.
//    The live service is still MANUAL/0 with the OLD marker, so the identity
//    is not proven and the token is set.
run "retry_after_failed_job" {
  command = apply
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"33333333-3333-4333-8333-333333333333\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"3\",\"observedGeneration\":\"3\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-3b\"}}}" }
  }
  plan_options {
    replace = [
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.95.0"
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-3b"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"22222222-2222-4222-8222-222222222222\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-2\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-333333333333\",\"uid\":\"job-uid-3\",\"labels\":{\"fleetdm-lifecycle-identity\":\"333333333333\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_FAILED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }

  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].name == "fleet-migrate-333333333333-ef2927" &&
      can(regex("^r[0-9]{12}$", google_cloud_run_v2_job.migration[0].run_execution_token)) &&
      terracurl_request.stop[0].method == "PATCH" &&
      output.migration_identity == "33333333-3333-4333-8333-333333333333"
    )
    error_message = "Retry must create a new job name with a token and re-send the stop."
  }
  assert {
    condition     = jsondecode(terracurl_request.restore[0].request_body).annotations["fleetdm.com/lifecycle-restored"] == "33333333-3333-4333-8333-333333333333" && google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-3b"
    error_message = "Successful retry must stage the new attempt and restore with the identity marker."
  }
}

// 10. Job succeeds but the target revision is not Ready (post-service
//     readiness read, data.terracurl_request.service_ready): restore's
//     precondition refuses, Fleet stays MANUAL/0 (no AUTOMATIC on the old
//     revision / migrated schema).
run "failed_rollout_no_restore" {
  command = apply
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"3\",\"observedGeneration\":\"3\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_FAILED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00010\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4\"},\"containers\":[{\"image\":\"fleetdm/fleet:v4.96.0\"}]}}" }
  }
  plan_options {
    replace = [
      terraform_data.identity[0],
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "44444444-4444-4444-8444-444444444444" }
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-4"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"33333333-3333-4333-8333-333333333333\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-3b\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-333333333333-ef2927\",\"uid\":\"job-uid-3b\",\"labels\":{\"fleetdm-lifecycle-identity\":\"333333333333\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }
  expect_failures = [terracurl_request.restore]
}

// 11. Plain next apply after the failed rollout: same job/attempt (no new
//     migration), still MANUAL, and a redeploy nonce in the attempt
//     annotation forces a fresh revision; restore runs once it is Ready.
// 10b. Unproven identity whose job already SUCCEEDED (failed rollout): an explicit
//      same-name job replacement would carry run_execution_token, so the
//      earlier-migration guard applies (read at plan) and an active orphan
//      execution blocks the PLAN: the job is never deleted.
run "guard_blocks_replacing_succeeded_job_of_unproven_identity" {
  command = plan
  plan_options {
    replace = [google_cloud_run_v2_job.migration[0]]
  }
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_FAILED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00010\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"33333333-3333-4333-8333-333333333333\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-444444444444\",\"uid\":\"job-uid-4\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-0123456789ab/executions/fleet-migrate-0123456789ab-r1\",\"job\":\"fleet-migrate-0123456789ab\",\"runningCount\":1}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

run "rollout_retry_redeploys_then_restores" {
  command = apply
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"3\",\"observedGeneration\":\"3\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4.a5f97103\"},\"containers\":[{\"image\":\"mirror.example.invalid/fleet:some-other-alias\"}]}}" }
  }
  plan_options {
    replace = [
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_FAILED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00010\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"33333333-3333-4333-8333-333333333333\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-444444444444\",\"uid\":\"job-uid-4\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }

  assert {
    condition = (
      output.declared_scaling_mode == "MANUAL" &&
      output.migration_job_name == "fleet-migrate-444444444444" &&
      google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-4.a5f97103"
    )
    error_message = "Failed rollout retry must keep the job, stay MANUAL and redeploy with a nonce."
  }
  assert {
    condition     = terracurl_request.restore[0].name == "fleet-lifecycle-restore-job-uid-4" && jsondecode(terracurl_request.restore[0].request_body).annotations["fleetdm.com/lifecycle-restored"] == "44444444-4444-4444-8444-444444444444"
    error_message = "Restore must follow the successful redeploy."
  }
}

// 12. Proven identity, job re-created (simulated with -replace, e.g. after an
//     out-of-band delete): token suppressed, declared AUTOMATIC, no new attempt,
//     so no stop: a reconstituted job never migrates while Fleet serves.
run "proven_job_recreate_suppresses_token" {
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"9\",\"observedGeneration\":\"9\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00009\",\"latestCreatedRevision\":\"fleet-api-00009\"}" }
  }
  command = apply
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  plan_options {
    replace = [
      google_cloud_run_v2_job.migration[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-4r"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"7\",\"observedGeneration\":\"7\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00001\",\"latestCreatedRevision\":\"fleet-api-00001\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4.a5f97103\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"fleet-migrate-444444444444\",\"uid\":\"job-uid-4\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].run_execution_token == null &&
      output.declared_scaling_mode == "AUTOMATIC" &&
      output.attempt_id == run.rollout_retry_redeploys_then_restores.attempt_id
    )
    error_message = "Re-created job of a proven identity must not carry a token or stop Fleet."
  }
}



// 12b. Proven identity, job re-created again (new UID => new restore key => the
//      restore is re-sent): its read-back is validated on its own response,
//      not on the settled pre-apply snapshot. Desired fields applied but the
//      generation not yet observed => the apply FAILS.
run "proven_job_recreate_unsettled_restore_fails" {
  command = apply
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  plan_options {
    replace = [
      google_cloud_run_v2_job.migration[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-4s"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"10\",\"observedGeneration\":\"10\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00010\",\"latestCreatedRevision\":\"fleet-api-00010\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-4r\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4r\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-444444444444\",\"uid\":\"job-uid-4r\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"12\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\"}" }
  }

  expect_failures = [data.terracurl_request.restore_verify]
}

// 12c. Plain retry: the identity is still proven (no stop, no token, no new
//      job); the live service is unsettled, so this attempt's nonce deploys a
//      fresh revision and the read-back must now show a settled service.
run "proven_job_recreate_unsettled_retry_converges" {
  command = apply
  variables {
    image = "fleetdm/fleet:v4.96.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"12\",\"observedGeneration\":\"11\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00010\",\"latestCreatedRevision\":\"fleet-api-00010\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-4s\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4s\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-444444444444\",\"uid\":\"job-uid-4s\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"13\",\"observedGeneration\":\"13\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\"}" }
  }

  assert {
    condition = (
      google_cloud_run_v2_job.migration[0].uid == "job-uid-4s" &&
      output.declared_scaling_mode == "AUTOMATIC" &&
      startswith(google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"], "job-uid-4s.") &&
      terracurl_request.restore[0].name == "fleet-lifecycle-restore-job-uid-4s"
    )
    error_message = "Retry must converge on the same proven identity/job with a fresh revision and no re-sent restore or migration."
  }
}
// ---------------------------------------------------------------------------
// Restore settlement. The restore read-back requires the marker and
// AUTOMATIC/min AND a settled control plane; desired fields alone are not a
// completed restore. The API-reported container image is never consulted
// (digest, unrelated alias or omitted below).
// ---------------------------------------------------------------------------

// 13. Upgrade (plain version tag) whose restore PATCH is accepted and whose
//     desired fields (marker, AUTOMATIC/1) are visible, terminal condition
//     SUCCEEDED, but observedGeneration lags generation: the apply FAILS.
run "restore_desired_fields_but_generation_lagging_fails" {
  command = apply
  plan_options {
    replace = [
      terraform_data.identity[0],
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.97.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "55555555-5555-4555-8555-555555555555" }
  }
  override_resource {
    target = google_cloud_run_v2_job.migration[0]
    values = {
      uid                = "job-uid-5"
      terminal_condition = [{ type = "Ready", state = "CONDITION_SUCCEEDED", reason = "", message = "" }]
    }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"10\",\"observedGeneration\":\"10\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00010\",\"latestCreatedRevision\":\"fleet-api-00010\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-4r\"},\"containers\":[{\"image\":\"fleetdm/fleet:v4.96.0\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-444444444444\",\"uid\":\"job-uid-4r\",\"labels\":{\"fleetdm-lifecycle-identity\":\"444444444444\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"12\",\"observedGeneration\":\"12\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"11\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:1111111111111111111111111111111111111111111111111111111111111111\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"12\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\"}" }
  }

  expect_failures = [data.terracurl_request.restore_verify]
}

// 14. Plain retry PLAN while the live service still shows the marker with a
//     lagging observedGeneration: the identity is migrated (proven: no stop,
//     no new job, declared AUTOMATIC) but not settled, so the attempt nonce
//     plans a fresh revision of THIS attempt instead of trusting the marker.
run "restore_lagging_retry_plan_redeploys_without_migration" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.97.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"12\",\"observedGeneration\":\"11\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:1111111111111111111111111111111111111111111111111111111111111111\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }

  assert {
    condition = (
      output.migration_proven == true &&
      output.declared_scaling_mode == "AUTOMATIC" &&
      output.migration_identity == "55555555-5555-4555-8555-555555555555" &&
      output.migration_job_name == "fleet-migrate-555555555555"
    )
    error_message = "A lagging restore must not re-run the migration or stop Fleet (identity is migrated)."
  }
  assert {
    condition     = google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-5.${substr(sha256("fleet-api-00011"), 0, 8)}"
    error_message = "An unsettled restore must be repaired by a fresh revision of the same attempt (nonce)."
  }
  assert {
    condition     = terracurl_request.restore[0].name == "fleet-lifecycle-restore-job-uid-5"
    error_message = "The restore must not be re-sent while its marker is present."
  }
}

// 15. Same retry applied: the service redeploys (nonce) and the read-back now
//     observes a settled control plane: success, still no new migration.
run "restore_lagging_retry_apply_recovers" {
  command = apply
  variables {
    image = "fleetdm/fleet:v4.97.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"12\",\"observedGeneration\":\"11\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:1111111111111111111111111111111111111111111111111111111111111111\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"11\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.x\"}}}" }
  }
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"11\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\"}" }
  }

  assert {
    condition = (
      output.migration_job_name == "fleet-migrate-555555555555" &&
      google_cloud_run_v2_job.migration[0].uid == "job-uid-5" &&
      startswith(google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"], "job-uid-5.") &&
      output.declared_scaling_mode == "AUTOMATIC"
    )
    error_message = "Retry must converge on the same job/attempt."
  }
}

// 16. Settled no-op for a plain tag while the API reports an unrelated alias
//     image and a RELEVANT execution is active: nothing changes (no nonce,
//     the earlier-execution guard only applies before a new migration).
run "settled_noop_ignores_api_image_and_guard" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.97.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"13\",\"observedGeneration\":\"13\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"},\"containers\":[{\"image\":\"mirror.example.invalid/fleet:some-other-alias\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migration/executions/fleet-migration-abcde\",\"job\":\"fleet-migration\",\"runningCount\":1}]}" }
  }

  assert {
    condition = (
      output.declared_scaling_mode == "AUTOMATIC" &&
      google_cloud_run_v2_service.fleet.template[0].annotations["fleetdm.com/lifecycle-attempt"] == "job-uid-5.settled" &&
      google_cloud_run_v2_service.fleet.template[0].containers[0].image == "fleetdm/fleet:v4.97.0"
    )
    error_message = "Settled no-op must keep the live attempt and declare the literal input image."
  }
}

// 17. Restore LRO failed earlier (marker absent, Fleet MANUAL) while the API
//     reports the revision image as a resolved digest: the next plain apply
//     re-sends the restore with a fresh key (attempt + settled are enough;
//     the reported image is not compared) and does not migrate.
run "restore_retry_ignores_reported_digest_image" {
  command = apply
  variables {
    image = "fleetdm/fleet:v4.97.0"
  }
  plan_options {
    replace = [terracurl_request.restore[0], terracurl_request.restore_wait[0]]
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"13\",\"observedGeneration\":\"13\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"44444444-4444-4444-8444-444444444444\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-4r\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:1111111111111111111111111111111111111111111111111111111111111111\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.service_ready[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"11\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"},\"containers\":[{\"image\":\"docker.io/fleetdm/fleet@sha256:1111111111111111111111111111111111111111111111111111111111111111\"}]}}" }
  }
  override_data {
    target = data.terracurl_request.stop_verify[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"12\",\"observedGeneration\":\"12\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\",\"annotations\":{},\"template\":{\"annotations\":{}}}" }
  }
  override_data {
    target = data.terracurl_request.restore_verify[0]
    values = { status_code = "200", response = "{\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"mock\"},\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"generation\":\"11\",\"observedGeneration\":\"11\",\"reconciling\":false,\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00011\",\"latestCreatedRevision\":\"fleet-api-00011\"}" }
  }

  assert {
    condition = (
      startswith(terracurl_request.restore[0].name, "fleet-lifecycle-restore-job-uid-5-r") &&
      jsondecode(terracurl_request.restore[0].request_body).annotations["fleetdm.com/lifecycle-restored"] == "55555555-5555-4555-8555-555555555555" &&
      output.migration_job_name == "fleet-migrate-555555555555" &&
      google_cloud_run_v2_job.migration[0].uid == "job-uid-5"
    )
    error_message = "A missing marker must re-send the restore (fresh key) without a migration, regardless of the reported image."
  }
}

// ---------------------------------------------------------------------------
// Earlier-migration guard (GET jobs/-/executions). Relevant job IDs:
// fleet-migration (earlier releases) and fleet-migrate-* (every identity).
// ---------------------------------------------------------------------------

// 18. New identity while the legacy fixed-name job has an active execution:
//     the inventory is read during apply after the attempt; the stop
//     precondition refuses, so Fleet is not stopped and no job is created.
run "guard_legacy_active_blocks_before_stop" {
  command = apply
  plan_options {
    replace = [
      terraform_data.identity[0],
      google_cloud_run_v2_job.migration[0],
      terracurl_request.stop[0],
      terracurl_request.stop_wait[0],
      time_sleep.drain[0],
      terracurl_request.restore[0],
      terracurl_request.restore_wait[0],
    ]
  }
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_resource {
    target = terraform_data.identity[0]
    values = { id = "66666666-6666-4666-8666-666666666666" }
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"14\",\"observedGeneration\":\"14\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"AUTOMATIC\",\"minInstanceCount\":1},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migration/executions/fleet-migration-abcde\",\"job\":\"fleet-migration\",\"runningCount\":1},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/nightly-report/executions/nightly-report-1\",\"job\":\"nightly-report\",\"runningCount\":1}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 19. A prior identity's orphan job (not in state; full Execution.job name) still running.
run "guard_prior_identity_orphan_active_full_job_name" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-0123456789ab/executions/fleet-migrate-0123456789ab-r1\",\"job\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-0123456789ab\",\"runningCount\":1}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 20. Same job: an OLDER execution still active while the newer (latest) one completed;
//     Execution.job omitted (job ID from Execution.name). Must block: the full
//     inventory is checked, not only the latest execution.
run "guard_older_execution_active_newer_completed" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-fedcba987654/executions/fleet-migrate-fedcba987654-new\",\"completionTime\":\"2026-10-01T00:00:00Z\"},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-fedcba987654/executions/fleet-migrate-fedcba987654-old\"}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 21. completionTime set but runningCount > 0 (e.g. cancelling): still active.
run "guard_completed_but_still_running_count" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migration/executions/fleet-migration-c\",\"job\":\"fleet-migration\",\"completionTime\":\"2026-10-01T00:00:00Z\",\"runningCount\":1}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 22. More than one page (nextPageToken): no partial inventory is trusted.
run "guard_truncated_inventory_blocks" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[],\"nextPageToken\":\"next\"}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 23. A 200 body that is not JSON is never an empty inventory.
run "guard_malformed_inventory_blocks" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "<html>not json</html>" }
  }

  expect_failures = [terracurl_request.stop]
}

// 24. A non-200 status (mock; the real request already fails on it) is never an empty inventory.
run "guard_non_200_inventory_blocks" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "403", response = "{\"error\":{\"code\":403}}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 25. An execution that names no job cannot be classified: blocks.
run "guard_unattributable_execution_blocks" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"createTime\":\"2026-10-01T00:00:00Z\"}]}" }
  }

  expect_failures = [terracurl_request.stop]
}

// 26. Relevant executions settled (omitted runningCount = 0) and an unrelated job
//     still running: the new migration may proceed.
run "guard_settled_or_unrelated_passes" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{\"executions\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migration/executions/fleet-migration-abcde\",\"job\":\"fleet-migration\",\"completionTime\":\"2026-10-01T00:00:00Z\"},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-0123456789ab/executions/x-1\",\"job\":\"fleet-migrate-0123456789ab\",\"completionTime\":\"2026-10-01T00:00:00Z\",\"runningCount\":0},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/nightly-report/executions/nightly-report-1\",\"job\":\"nightly-report\",\"runningCount\":1},{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrations-report/executions/r-1\",\"job\":\"fleet-migrations-report\",\"runningCount\":1}]}" }
  }

  assert {
    condition     = terracurl_request.stop[0].method == "PATCH" && google_cloud_run_v2_job.migration[0].name == "fleet-migrate-666666666666"
    error_message = "With no relevant active execution the new migration must be planned."
  }
}

// 27. A valid 200 body without an executions array is a legitimately empty region.
run "guard_empty_region_passes" {
  command = plan
  variables {
    image = "fleetdm/fleet:v4.98.0"
  }
  override_data {
    target = data.terracurl_request.service_live[0]
    values = { status_code = "200", response = "{\"name\":\"projects/fictional-proj/locations/us-central1/services/fleet-api\",\"generation\":\"15\",\"observedGeneration\":\"15\",\"reconciling\":false,\"scaling\":{\"scalingMode\":\"MANUAL\"},\"traffic\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"trafficStatuses\":[{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST\",\"percent\":100}],\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"},\"latestReadyRevision\":\"fleet-api-00012\",\"latestCreatedRevision\":\"fleet-api-00012\",\"annotations\":{\"fleetdm.com/lifecycle-restored\":\"55555555-5555-4555-8555-555555555555\",\"fleetdm.com/lifecycle-restore-key\":\"job-uid-5-r1\"},\"template\":{\"annotations\":{\"fleetdm.com/lifecycle-attempt\":\"job-uid-5.settled\"}}}" }
  }
  override_data {
    target = data.terracurl_request.jobs_live[0]
    values = { status_code = "200", response = "{\"jobs\":[{\"name\":\"projects/fictional-proj/locations/us-central1/jobs/fleet-migrate-555555555555\",\"uid\":\"job-uid-5\",\"labels\":{\"fleetdm-lifecycle-identity\":\"555555555555\"},\"terminalCondition\":{\"type\":\"Ready\",\"state\":\"CONDITION_SUCCEEDED\"}}]}" }
  }
  override_data {
    target = data.terracurl_request.executions_live[0]
    values = { status_code = "200", response = "{}" }
  }

  assert {
    condition     = terracurl_request.stop[0].method == "PATCH" && google_cloud_run_v2_job.migration[0].name == "fleet-migrate-666666666666"
    error_message = "With no relevant active execution the new migration must be planned."
  }
}
