locals {
  keypairs = var.keypairs != null ? var.keypairs : {
    current = {
      public_key  = var.public_key
      private_key = var.private_key
    }
  }

  keypair_names = var.keypairs != null ? keys(var.keypairs) : ["current"]
}

data "aws_s3_bucket" "software_installers" {
  bucket = var.s3_bucket
}

data "aws_iam_policy_document" "software_installers_secret" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.software_installers.arn]
  }
}

resource "aws_iam_policy" "software_installers_secret" {
  policy = data.aws_iam_policy_document.software_installers_secret.json
}

resource "aws_cloudfront_public_key" "software_installers" {
  for_each = var.key_group_id == null ? toset(nonsensitive(local.keypair_names)) : toset([])

  comment     = each.key == "current" ? "${var.customer} software installers public key" : "${var.customer} software installers public key ${each.key}"
  encoded_key = local.keypairs[each.key].public_key
  name        = each.key == "current" ? "${var.customer}-software-installers" : "${var.customer}-software-installers-${each.key}"
}

moved {
  from = aws_cloudfront_public_key.software_installers[0]
  to   = aws_cloudfront_public_key.software_installers["current"]
}

resource "aws_cloudfront_key_group" "software_installers" {
  count   = var.key_group_id == null ? 1 : 0
  comment = "${var.customer} software installers key group"
  items   = values(aws_cloudfront_public_key.software_installers)[*].id
  name    = "${var.customer}-software-installers-group"
}

resource "aws_secretsmanager_secret" "software_installers" {
  name = "${var.customer}-software-installers"
}

resource "aws_secretsmanager_secret_version" "software_installers" {
  secret_id = aws_secretsmanager_secret.software_installers.id
  secret_string = jsonencode({
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY   = local.keypairs[var.active_keypair_name].private_key
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY    = local.keypairs[var.active_keypair_name].public_key
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL                       = "https://${module.cloudfront_software_installers.cloudfront_distribution_domain_name}"
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY_ID = var.public_key_id == null ? aws_cloudfront_public_key.software_installers[var.active_keypair_name].id : var.public_key_id
  })
}

data "aws_s3_bucket" "logging" {
  bucket = var.logging_s3_bucket
}

module "cloudfront_software_installers" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "5.2.0"

  comment = "${var.customer} software installers"
  enabled = true
  # We're not using IPV6 elsewhere.  Turn it on across the board when we want it.
  is_ipv6_enabled     = false
  price_class         = "PriceClass_All"
  retain_on_delete    = false
  wait_for_deployment = false

  create_origin_access_identity = false

  create_origin_access_control = true
  origin_access_control = {
    "${var.customer}-software-installers" = {
      description      = "${var.customer}-software-installers"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # setup a logging bucket
  logging_config = var.enable_logging == true ? {
    bucket = data.aws_s3_bucket.logging.bucket_domain_name
    prefix = var.logging_s3_prefix
    } : {
    bucket = null
    prefix = null
  }

  origin = {
    s3_one = {
      domain_name           = data.aws_s3_bucket.software_installers.bucket_regional_domain_name
      origin_access_control = "${var.customer}-software-installers"
    }
  }

  default_cache_behavior = {
    target_origin_id       = "s3_one"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods    = ["GET", "HEAD", "OPTIONS"]
    cached_methods     = ["GET", "HEAD"]
    compress           = true
    query_string       = true
    trusted_key_groups = var.key_group_id != null ? [var.key_group_id] : [aws_cloudfront_key_group.software_installers[0].id]
  }

  ordered_cache_behavior = []
}
