# Move these to the main terraform
# data "aws_kms_secrets" "software_installers_private_key" {
#   secret {
#     name    = "FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY"
#     key_id  = var.kms_key_id
#     payload = file(var.private_key)
#   }
# }
# 
# data "aws_kms_secrets" "software_installers_public_key" {
#   secret {
#     name    = "FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY"
#     key_id  = var.kms_key_id
#     payload = file(var.public_key)
#   }
# }

data "aws_s3_bucket" "software_installers" {
  bucket = var.s3_bucket
}

data "aws_iam_policy_document" "software_installers_secret" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.software_installers.arn]
  }
}

resource "aws_iam_policy" "software_installers_secret" {
  policy = data.aws_iam_policy_document.software_installers_secret.json
}

resource "aws_cloudfront_public_key" "software_installers" {
  comment     = "${var.customer} software installers public key"
  encoded_key = var.public_key
  name        = "${var.customer}-software-installers"
}

resource "aws_cloudfront_key_group" "software_installers" {
  comment = "${var.customer} software installers key group"
  items   = [aws_cloudfront_public_key.software_installers.id]
  name    = "${var.customer}-software-installers-group"
}

resource "aws_secretsmanager_secret" "software_installers" {
  name = "${var.customer}-software-installers"
}

resource "aws_secretsmanager_secret_version" "software_installers" {
  secret_id = aws_secretsmanager_secret.software_installers.id
  secret_string = jsonencode({
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY = var.private_key
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLC_KEY = var.public_key
  })
  # private key data
}

module "cloudfront_software_installers" {
  source = "terraform-aws-modules/cloudfront/aws"

  # Will we need an alias?  Should this be optional?
  # aliases = ["cdn.example.com"]

  comment = "${var.customer} software installers"
  enabled = true
  # We're not using IPV6 elsewhere.  Turn it on across the board when we want it.
  is_ipv6_enabled     = false
  price_class         = "PriceClass_All"
  retain_on_delete    = false
  wait_for_deployment = false

  create_origin_access_identity = true
  origin_access_identities = {
    s3_bucket = "${var.customer} CloudFront can access software installers bucket"
  }

  origin_access_control = {
    s3 = {
      description      = "Require signatures"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # setup a logging bucket
  # logging_config = {
  #   bucket = "logs-my-cdn.s3.amazonaws.com"
  # }

  origin = {
    s3_one = {
      domain_name = data.aws_s3_bucket.software_installers.bucket_domain_name
      s3_origin_config = {
        origin_access_identity = "s3_bucket"
      }
    }
  }

  default_cache_behavior = {
    target_origin_id       = "s3_one"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
    query_string    = true
  }

  ordered_cache_behavior = []

}
