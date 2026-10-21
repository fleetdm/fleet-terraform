data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat, Inc.

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  instance_configuration = merge({
    type                  = "t3a.large"
    key_name              = null
    iam_instance_profile  = null
    volume_size           = 50
    volume_type           = "gp3"
    volume_iops           = null
    volume_throughput     = null
    delete_on_termination = true
  }, var.instance_configuration)

  extra_environment = {
    for pair in var.fleet_config.extra_environment_variables :
    pair.key => pair.value
  }

  fleet_env_map = merge(
    {
      FLEET_SERVER_PRIVATE_KEY = random_password.fleet_server_private_key.result
    },
    local.extra_environment,
  )

  fleet_download_url = "https://github.com/fleetdm/fleet/releases/download/fleet-${var.fleet_config.fleet_version}/fleet_${var.fleet_config.fleet_version}_linux.tar.gz"

  ansible_extra_vars = jsonencode({
    fleet_download_url = local.fleet_download_url
    fleet_archive_path = "/tmp/fleet.tar.gz"
    fleet_extract_dir  = "/opt/fleet"
    fleet_binary_path  = "/opt/fleet/fleet"
    fleet_env_file     = "/etc/fleet/fleet_env"
    fleet_env_map      = local.fleet_env_map
    fleet_service_user = var.fleet_config.service_user
    fleet_service_name = var.name
    tls_domains        = var.fleet_config.tls.domains
    tls_email          = var.fleet_config.tls.email
  })

  ansible_repo_url    = var.ansible_source.repo_url
  ansible_repo_ref    = var.ansible_source.ref
  ansible_repo_path   = "/opt/fleet-terraform"
  ansible_sparse_path = "ec2/byo-vpc/byo-db/ansible"
  ansible_playbook    = "ec2/byo-vpc/byo-db/ansible/site.yml"

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    ansible_extra_vars  = local.ansible_extra_vars
    ansible_repo_url    = local.ansible_repo_url
    ansible_repo_ref    = local.ansible_repo_ref
    ansible_repo_path   = local.ansible_repo_path
    ansible_sparse_path = local.ansible_sparse_path
    ansible_playbook    = local.ansible_playbook
  })

  security_group_ids = length(var.security_group_ids) == 0 ? [aws_security_group.fleet[0].id] : var.security_group_ids
}

resource "random_password" "fleet_server_private_key" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+[]{}"
}

resource "aws_security_group" "fleet" {
  count       = length(var.security_group_ids) == 0 ? 1 : 0
  name_prefix = "${var.name}-fleet-"
  description = "Security group for Fleet EC2 instance"
  vpc_id      = var.vpc_id

  egress {
    description      = "Allow all egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      description      = lookup(ingress.value, "description", null)
      from_port        = ingress.value.from_port
      to_port          = ingress.value.to_port
      protocol         = ingress.value.protocol
      cidr_blocks      = lookup(ingress.value, "cidr_blocks", [])
      ipv6_cidr_blocks = lookup(ingress.value, "ipv6_cidr_blocks", [])
      security_groups  = lookup(ingress.value, "security_groups", [])
      prefix_list_ids  = lookup(ingress.value, "prefix_list_ids", [])
    }
  }
}

resource "aws_instance" "fleet" {
  ami                         = data.aws_ami.rhel.id
  instance_type               = local.instance_configuration.type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = local.security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  iam_instance_profile        = local.instance_configuration.iam_instance_profile
  key_name                    = local.instance_configuration.key_name
  user_data                   = local.cloud_init
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = local.instance_configuration.volume_size
    volume_type           = local.instance_configuration.volume_type
    iops                  = local.instance_configuration.volume_iops
    throughput            = local.instance_configuration.volume_throughput
    delete_on_termination = local.instance_configuration.delete_on_termination
    encrypted             = true
  }

  tags = merge(
    {
      Name = "${var.name}-fleet"
    },
    var.tags,
  )
}
