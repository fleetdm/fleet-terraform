output "extra_secrets" {
  value = {
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_PRIVATE_KEY = "${aws_secretsmanager_secret.software_installers.arn}:FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_PRIVATE_KEY::"
  }
}

output "extra_environment_variables" {
  value = {
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL         = "https://${module.cloudfront_software_installers.cloudfront_distribution_domain_name}"
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_PAIR_KEY_ID = aws_cloudfront_public_key.software_installers.id
  }
}

output "extra_iam_policies" {
  value = [aws_iam_policy.software_installers_secret.arn]
}

output "cloudfront_arn" {
  value = module.cloudfront_software_installers.cloudfront_distribution_arn
}

output "cloudfront_s3_policy" {
  value = data.aws_iam_policy_document.software_installers_bucket.json
}

output "cloudfront_kms_policies" {
  value = [{
    sid    = "AllowOriginAccessIdentity"
    effect = "Allow"
    principals = [{
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }]
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    conditions = [{
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront_software_installers.cloudfront_distribution_arn]
    }]
  }]
}
