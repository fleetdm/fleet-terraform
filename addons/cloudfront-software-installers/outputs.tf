output "extra_secrets"  {
  value = {
    FLEET_S3_SOFTWARE_INSTALLERS_CLOUDFRONT_PRIVATE_KEY = var.private_key
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
