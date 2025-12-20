variable "name" {
  type        = string
  description = "Base name to use for created resources."
  default     = "fleet"
}

variable "vpc_id" {
  type        = string
  description = "Identifier of the VPC that hosts the Fleet instance."
}

variable "subnet_id" {
  type        = string
  description = "Subnet where the Fleet instance will be launched."
}

variable "associate_public_ip_address" {
  type        = bool
  description = "Whether to associate a public IP address to the Fleet instance."
  default     = true
}

variable "security_group_ids" {
  type        = list(string)
  description = "Existing security group IDs to attach to the Fleet instance. If empty, a security group will be created."
  default     = []
}

variable "ingress_rules" {
  description = <<EOT
Ingress rules applied when this module creates the security group. Each rule allows HTTP(S) access required for Fleet/Nginx.
EOT
  type = list(object({
    description      = optional(string, null)
    from_port        = number
    to_port          = number
    protocol         = string
    cidr_blocks      = optional(list(string), [])
    ipv6_cidr_blocks = optional(list(string), [])
    security_groups  = optional(list(string), [])
    prefix_list_ids  = optional(list(string), [])
  }))
  default = [
    {
      description      = "Allow HTTP"
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    },
    {
      description      = "Allow HTTPS"
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  ]
}

variable "instance_configuration" {
  description = "EC2 instance configuration overrides."
  type = object({
    type                  = optional(string, "t3a.large")
    key_name              = optional(string)
    iam_instance_profile  = optional(string)
    volume_size           = optional(number, 50)
    volume_type           = optional(string, "gp3")
    volume_iops           = optional(number)
    volume_throughput     = optional(number)
    delete_on_termination = optional(bool, true)
  })
  default = {}
}

variable "fleet_config" {
  description = "Configuration values that control Fleet bootstrap settings."
  type = object({
    fleet_version = string
    service_user  = optional(string, "fleet")
    extra_environment_variables = optional(list(object({
      key   = string
      value = string
    })), [])
    tls = object({
      domains = list(string)
      email   = string
    })
  })

  validation {
    condition     = length(var.fleet_config.tls.domains) > 0
    error_message = "Provide at least one domain in fleet_config.tls.domains for certificate issuance."
  }
}

variable "ansible_source" {
  description = "Location of the Fleet Terraform repository to pull Ansible content from."
  type = object({
    repo_url = string
    ref      = string
  })
  default = {
    repo_url = "https://github.com/fleetdm/fleet-terraform.git"
    ref      = "main"
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to created resources."
  default     = {}
}
