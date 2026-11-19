output "instance_id" {
  description = "Identifier of the Fleet EC2 instance."
  value       = aws_instance.fleet.id
}

output "instance_public_ip" {
  description = "Public IPv4 address assigned to the Fleet EC2 instance."
  value       = aws_instance.fleet.public_ip
}

output "security_group_ids" {
  description = "Security groups attached to the Fleet EC2 instance."
  value       = local.security_group_ids
}

output "fleet_server_private_key" {
  description = "Generated Fleet server private key."
  value       = random_password.fleet_server_private_key.result
  sensitive   = true
}
