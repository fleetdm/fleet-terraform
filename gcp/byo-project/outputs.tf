output "fleet_application_url" {
  description = "The primary URL to access the Fleet application (via the Load Balancer)."
  value       = "https://${google_dns_record_set.fleet_dns_record.name}"
}

output "load_balancer_ip_address" {
  description = "The external IP address of the HTTP(S) Load Balancer."
  value       = module.fleet_lb.external_ip
}

output "cloud_run_service_name" {
  description = "The name of the deployed Fleet Cloud Run service."
  value       = module.fleet-service.service_name
}

output "cloud_run_service_location" {
  description = "The location of the deployed Fleet Cloud Run service."
  value       = module.fleet-service.location // Check the actual output name
}

output "mysql_instance_name" {
  description = "The name of the Cloud SQL for MySQL instance."
  value       = module.mysql.instance_name
}

output "mysql_instance_connection_name" {
  description = "The connection name for the Cloud SQL instance (used by Cloud SQL Proxy)."
  value       = module.mysql.instance_connection_name
}

output "redis_instance_name" {
  description = "The name of the Memorystore for Redis instance."
  value       = module.memstore.id
}

output "redis_host" {
  description = "The host IP address of the Memorystore for Redis instance."
  value       = module.memstore.host
}

output "redis_port" {
  description = "The port number of the Memorystore for Redis instance."
  value       = module.memstore.port
}

output "software_installers_bucket_name" {
  description = "The name of the GCS bucket for Fleet software installers."
  value       = google_storage_bucket.software_installers.name
}

output "software_installers_bucket_url" {
  description = "The gsutil URL of the GCS bucket for Fleet software installers."
  value       = google_storage_bucket.software_installers.url
}

output "fleet_service_account_email" {
  description = "The email address of the service account used by the Fleet Cloud Run service."
  value       = google_service_account.fleet_run_sa.email
}

output "dns_managed_zone_name" {
  description = "The name of the Cloud DNS managed zone created for Fleet."
  value       = google_dns_managed_zone.fleet_dns_zone.name
}

output "dns_managed_zone_name_servers" {
  description = "The authoritative name servers for the created Cloud DNS managed zone. Delegate your domain to these."
  value       = google_dns_managed_zone.fleet_dns_zone.name_servers
}

output "vpc_network_name" {
  description = "The name of the VPC network created."
  value       = module.vpc.network_name
}

output "vpc_network_self_link" {
  description = "The self-link of the VPC network created."
  value       = module.vpc.network_self_link
}

output "vpc_subnets_names" {
  description = "List of subnet names created in the VPC."
  value       = module.vpc.subnets_names
}

output "cloud_router_name" {
  description = "The name of the Cloud Router created for NAT."
  value       = module.cloud_router.router.name
}
