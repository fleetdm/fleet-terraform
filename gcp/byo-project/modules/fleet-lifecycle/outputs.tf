output "service_name" {
  description = "Fleet Cloud Run service name."
  value       = google_cloud_run_v2_service.fleet.name
}

output "service_location" {
  description = "Fleet Cloud Run service location."
  value       = google_cloud_run_v2_service.fleet.location
}

output "migration_job_name" {
  description = "Current per-attempt migration job name (null when migrations are disabled)."
  value       = var.migration_enabled ? google_cloud_run_v2_job.migration[0].name : null
}

output "migration_identity" {
  description = "Current migration identity UUID (null when migrations are disabled)."
  value       = var.migration_enabled ? terraform_data.identity[0].id : null
}

output "migration_proven" {
  description = "True when the live service carries the restore marker of the current identity (read at plan)."
  value       = local.proven
}

output "declared_scaling_mode" {
  description = "Scaling mode declared on the service in this run."
  value       = local.serving ? "AUTOMATIC" : "MANUAL"
}

# Full objects for tests/inspection; sensitive because the env carries the
# license key and other configuration.
output "service" {
  description = "Full service resource (sensitive)."
  value       = google_cloud_run_v2_service.fleet
  sensitive   = true
}

output "migration_job" {
  description = "Full migration job resource or null (sensitive)."
  value       = one(google_cloud_run_v2_job.migration)
  sensitive   = true
}

output "migration_identity_triggers" {
  description = "Inputs of the migration identity (no secrets). Any change => new identity => one fresh migration."
  value       = var.migration_enabled ? terraform_data.identity[0].triggers_replace : null
}

output "attempt_id" {
  description = "Current attempt ID (changes only with the job name). Exposed for tests/inspection."
  value       = var.migration_enabled ? terraform_data.attempt[0].id : null
}

output "tmp_volume" {
  description = "The /tmp volume as declared on the service template (null when tmp_volume_config.enable = false): name, medium, size_limit and the container mount_path. Read from the service resource, not from the input."
  value = (
    length(google_cloud_run_v2_service.fleet.template[0].volumes) == 0 ? null : {
      name       = google_cloud_run_v2_service.fleet.template[0].volumes[0].name
      medium     = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].medium
      size_limit = google_cloud_run_v2_service.fleet.template[0].volumes[0].empty_dir[0].size_limit
      mount_path = one([
        for m in google_cloud_run_v2_service.fleet.template[0].containers[0].volume_mounts :
        m.mount_path if m.name == google_cloud_run_v2_service.fleet.template[0].volumes[0].name
      ])
    }
  )
}
