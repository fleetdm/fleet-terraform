data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "software_installers_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.software_installers.arn}/*"]
    effect    = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront_software_installers.cloudfront_distribution_arn]
    }
  }
}

data "aws_s3_bucket" "software_installers" {
  bucket = var.s3_bucket
}

resource "aws_s3_bucket_policy" "software_installers" {
  bucket = data.aws_s3_bucket.software_installers.bucket
  policy = data.aws_iam_policy_document.software_installers_bucket.json
}

data "aws_iam_policy_document" "software_installers_kms" {
  statement {
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }
  statement {
    sid    = "AllowOriginAccessIdentity"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront_software_installers.cloudfront_distribution_arn]
    }
  }
}

resource "aws_kms_key_policy" "software_installers" {
  key_id = var.s3_kms_key_id
  policy = data.aws_iam_policy_document.software_installers_kms.json
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
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY   = var.private_key
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLC_KEY     = var.public_key
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL                       = "https://${module.cloudfront_software_installers.cloudfront_distribution_domain_name}"
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY_ID = aws_cloudfront_public_key.software_installers.id
  })
}

data "aws_s3_bucket" "logging" {
  bucket = var.logging_s3_bucket
}

module "cloudfront_software_installers" {
  source = "terraform-aws-modules/cloudfront/aws"

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
      domain_name           = data.aws_s3_bucket.software_installers.bucket_domain_name
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
    trusted_key_groups = [aws_cloudfront_key_group.software_installers.id]
  }

  ordered_cache_behavior = []

}
