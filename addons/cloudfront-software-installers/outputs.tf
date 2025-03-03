output "extra_secrets" {
  value = {
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY   = "${aws_secretsmanager_secret.software_installers.arn}:FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PRIVATE_KEY::"
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY_ID = "${aws_secretsmanager_secret.software_installers.arn}:FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL_SIGNING_PUBLIC_KEY_ID::"
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL                       = "${aws_secretsmanager_secret.software_installers.arn}:FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_URL::"
  }
}

output "extra_execution_iam_policies" {
  value = [aws_iam_policy.software_installers_secret.arn]
}

output "cloudfront_arn" {
  value = module.cloudfront_software_installers.cloudfront_distribution_arn
}
