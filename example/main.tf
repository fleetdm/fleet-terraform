# This example doesn't cover using a remote backend for storing the current
# terraform state in S3 with a lock in DynamoDB (ideal for AWS) or other
# methods. If using automation to apply the configuration or if multiple people
# will be managing these resources, this is recommended.
#
# See https://developer.hashicorp.com/terraform/language/settings/backends/s3
# for reference.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.11.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-2"
}

locals {
  # Change these to match your environment. Create or use a fully
  # qualified domain (fqdn) and a VPC in AWS.
  domain_name = "fleet.example.com"
  vpc_name    = "fleet-vpc"
  # This creates a subdomain in AWS to manage DNS Records.
  # This allows for easy validation of TLS Certificates via ACM and
  # the use of alias records to the load balancer.  Please note if
  # this is a subdomain that NS records will be needed to be created
  # in the primary zone.  These NS records will be included in the outputs
  # of this terraform run.
  zone_name = "fleet.example.com"

  # Bucket names need to be unique across AWS.  Change this to a friendly
  # name to make finding carves in s3 easier later.  Uncomment if using
  # s3 carves.
  # osquery_carve_bucket_name   = "fleet-osquery-carve"
  # Uncomment if using Firehose logging destinations.
  # osquery_results_bucket_name = "fleet-osquery-results"
  # osquery_status_bucket_name  = "fleet-osquery-status"

  # Extra ENV Vars for Fleet customization can be set here.
  fleet_environment_variables = {
    # Uncomment and provide license key to unlock premium features.
    #      FLEET_LICENSE_KEY = "<enter_license_key>"
    # JSON logging improves the experience with Cloudwatch Log Insights
    FLEET_LOGGING_JSON                      = "true"
    FLEET_MYSQL_MAX_OPEN_CONNS              = "10"
    FLEET_MYSQL_READ_REPLICA_MAX_OPEN_CONNS = "10"
    # Vulnerabilities is a premium feature.
    # Uncomment as this is a writable location in the container.
    # FLEET_VULNERABILITIES_DATABASES_PATH    = "/home/fleet"
    FLEET_REDIS_MAX_OPEN_CONNS = "500"
    FLEET_REDIS_MAX_IDLE_CONNS = "500"
  }
  # Used in the optional allowlist below
  # Import allowlist from text file
  # allowlist_cidrs = split("\n", chomp(file("${path.module}/allowlist.txt")))

  # Only 5 IPs allowed per rule
  # https_listener_rules = [for i in range(0, length(local.allowlist_cidrs), 5) : {
  #   priority             = i / 5 + 5
  #   actions = [{
  #     type               = "forward"
  #     target_group_index = 0
  #   }]
  #   conditions = [{
  #     source_ips = slice(local.allowlist_cidrs, i, min(i + 5, length(local.allowlist_cidrs)))
  #   }]
  # }]
}

module "fleet" {
  source          = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.18.2"
  certificate_arn = module.acm.acm_certificate_arn

  vpc = {
    # By default, Availabililty zones for us-east-2 are configured. If an alternative region is desired,
    # configure the azs (3 required) variable below to the desired region.  If you have an exported AWS-REGION or a
    # region declared in ~/.aws/config, this value must match the region declared below.
    name = local.vpc_name
    # azs = ["ca-central-1a", "ca-central-1b", "ca-central-1d"]
  }

  fleet_config = {
    # To avoid pull-rate limiting from dockerhub, consider using our quay.io mirror
    # for the Fleet image. e.g. "quay.io/fleetdm/fleet:v4.67.0"
    image = "fleetdm/fleet:v4.73.2" # override default to deploy the image you desire
    # See https://fleetdm.com/docs/deploy/reference-architectures#aws for appropriate scaling
    # memory and cpu.
    autoscaling = {
      min_capacity = 2
      max_capacity = 5
    }
    # 4GB Required for vulnerability scanning.  512MB works without.
    mem = 4096
    cpu = 512
    extra_environment_variables = merge(
      local.fleet_environment_variables,
      # uncomment if using s3 carves
      # module.osquery-carve.fleet_extra_environment_variables
      # uncomment if using firehose
      # module.firehose-logging.fleet_extra_environment_variables
    )
    extra_secrets = concat(
      module.mdm.extra_secrets,
    )
    extra_execution_iam_policies = concat(
      module.mdm.extra_execution_iam_policies,
    )
    # extra_iam_policies = concat(
    # uncomment if using a3 carves
    # module.osquery-carve.fleet_extra_iam_policies,
    # uncomment if using firehose
    # module.firehose-logging.fleet_extra_iam_policies,
    # )
  }
  rds_config = {
    # See https://fleetdm.com/docs/deploy/reference-architectures#aws for instance classes.
    instance_class = "db.t4g.medium"
    # Prevents edge case render failure in Audit log on the home screen.
    db_parameters = {
      # 8mb up from 262144 (256k) default
      sort_buffer_size = 8388608
    }
    # Uncomment to specify the RDS engine version
    # engine_version = "8.0.mysql_aurora.3.08.2"
    # Uncomment to use more or fewer replicas
    # replicas = 2
  }
  redis_config = {
    # See https://fleetdm.com/docs/deploy/reference-architectures#aws for instance types.
    instance_type = "cache.t4g.small"
    # Note these parameters help performance with large/complex live queries.
    # See https://github.com/fleetdm/fleet/blob/main/docs/Contributing/Troubleshooting-live-queries.md#1-redis for details.
    parameter = [
      { name = "client-output-buffer-limit-pubsub-hard-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-seconds", value = 0 },
    ]
  }
  alb_config = {
    # Script execution can run for up to 300s plus overhead.
    # Ensure the load balancer does not 5XX before we have results.
    idle_timeout = 905
    # Optionally deploy load balancer as an internal load balancer
    # internal = true
    # optionally set deletion protection on (true) or off (false)
    # enable_deletion_protection = true
    # Optionally Remove X-Forwarded-For header
    # xff_header_processing_mode = "remove"
    # See https://github.com/terraform-aws-modules/terraform-aws-alb/blob/v9.17.0/examples/complete-alb/main.tf#L383-L393.
    # All listener configs on the https listener can be overridden, but the following are the primary intent to be configurable.
    # https_overrides = {
    #   routing_http_response_server_enabled                                = false
    #   routing_http_response_strict_transport_security_header_value        = "max-age=31536000; includeSubDomains; preload"
    #   routing_http_response_access_control_allow_origin_header_value      = "https://example.com"
    #   routing_http_response_access_control_allow_methods_header_value     = "TRACE,GET"
    #   routing_http_response_access_control_allow_headers_header_value     = "Accept-Language,Content-Language"
    #   routing_http_response_access_control_allow_credentials_header_value = "true"
    #   routing_http_response_access_control_expose_headers_header_value    = "Cache-Control"
    #   routing_http_response_access_control_max_age_header_value           = 86400
    #   routing_http_response_content_security_policy_header_value          = "*"
    #   routing_http_response_x_content_type_options_header_value           = "nosniff"
    #   routing_http_response_x_frame_options_header_value                  = "SAMEORIGIN"
    # }
    # Optional rules to allowlist only osquery/orbit traffic and allowed IPs.
    # https_listener_rules = concat([{
    #   priority             = 9000
    #   actions = [{
    #     type         = "fixed-response"
    #     content_type = "text/html"
    #     status_code  = "403"
    #     message_body = "<h1><center>403 Forbidden</center></h1>"
    #   }]
    #   conditions = [{
    #     path_patterns = ["*"]
    #   }]
    #   }, {
    #   priority             = 1
    #   actions = [{
    #     type               = "forward"
    #     target_group_index = 0
    #   }]
    #   conditions = [{
    #     path_patterns = [
    #       "/api/osquery/*",
    #       "/api/*/osquery/*",
    #       "/api/*/orbit/*",
    #     ]
    #   }]
    #   }, {
    #   priority             = 2
    #   actions = [{
    #     type               = "forward"
    #     target_group_index = 0
    #   }]
    #   conditions = [{
    #     path_patterns = [
    #       "/api/*/fleet/device/*",
    #       "/mdm/*",
    #       "/api/mdm/apple/enroll",
    #     ]
    #   }]
    #   }, {
    #   priority             = 3
    #   actions = [{
    #     type               = "forward"
    #     target_group_index = 0
    #   }]
    #   conditions = [{
    #     path_patterns = [
    #       "/device/*",
    #       "/api/*/fleet/mdm/*",
    #       "/assets/*",
    #     ]
    #   }]
    #   }, {
    #   priority             = 4
    #   actions = [{
    #     type               = "forward"
    #     target_group_index = 0
    #   }]
    #   conditions = [{
    #     path_patterns = [
    #       "/api/mdm/microsoft/*",
    #       "/api/fleet/device/ping"
    #     ]
    #   }]
    # }], local.https_listener_rules)
  }
}

# Migrations will handle scaling Fleet to 0 running containers before running the DB migration task.
# This module will also handle scaling back up once migrations complete.
# NOTE: This requires the aws cli to be installed on the device running terraform as terraform
# doesn't directly support all the features required.  the aws cli is invoked via a null-resource.

module "migrations" {
  source                   = "github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.1.0"
  ecs_cluster              = module.fleet.byo-vpc.byo-db.byo-ecs.service.cluster
  task_definition          = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.family
  task_definition_revision = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.revision
  subnets                  = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].subnets
  security_groups          = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].security_groups
  ecs_service              = module.fleet.byo-vpc.byo-db.byo-ecs.service.name
  desired_count            = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  min_capacity             = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  
  depends_on = [
    module.fleet, 
  ]
}

# Enable if using s3 for carves
# module "osquery-carve" {
#   source = "github.com/fleetdm/fleet-terraform/addons/osquery-carve?depth=1&ref=tf-mod-addon-osquery-carve-v1.1.1"
#   osquery_carve_s3_bucket = {
#     name = local.osquery_carve_bucket_name
#   }
# }

# Uncomment if using firehose logging destination
# module "firehose-logging" {
#   source = "github.com/fleetdm/fleet-terraform/addons/logging-destination-firehose?depth=1&ref=tf-mod-addon-logging-destination-firehose-v1.2.4"
#   osquery_results_s3_bucket = {
#     name = local.osquery_results_bucket_name
#   }
#   osquery_status_s3_bucket = {
#     name = local.osquery_status_bucket_name
#   }
# }

## MDM Secret payload

# See https://github.com/fleetdm/fleet-terraform/blob/tf-mod-addon-mdm-v2.0.0/addons/mdm/README.md#abm
# Per that document, both Windows and Mac will use the same SCEP secret under the hood.  Currently only
# the Windows MDM secrets still use this as the all Mac MDM is managed via the Fleet UI and is therefore
# disabled in the module.

module "mdm" {
  source             = "github.com/fleetdm/fleet-terraform/addons/mdm?depth=1&ref=tf-mod-addon-mdm-v2.0.0"
  apn_secret_name    = null
  scep_secret_name   = "fleet-scep"
  abm_secret_name    = null
  enable_apple_mdm   = false
  enable_windows_mdm = true
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "4.3.1"

  domain_name = local.domain_name
  # If you change the route53 zone to a data source this needs to become "data.aws_route53_zone.main.id"
  zone_id = aws_route53_zone.main.id

  wait_for_validation = true
}

# If you already are managing your zone in AWS in the same account,
# this resource could be swapped with a data source instead to
# read the properties of that resource.
resource "aws_route53_zone" "main" {
  name = local.zone_name
}

resource "aws_route53_record" "main" {
  # If you change the route53_zone to a data source this also needs to become "data.aws_route53_zone.main.id"
  zone_id = aws_route53_zone.main.id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = module.fleet.byo-vpc.byo-db.alb.lb_dns_name
    zone_id                = module.fleet.byo-vpc.byo-db.alb.lb_zone_id
    evaluate_target_health = true
  }
}

# Ensure that these records are added to the parent DNS zone
# Delete this output if you switched the route53 zone above to a data source.
output "route53_name_servers" {
  value = aws_route53_zone.main.name_servers
}
