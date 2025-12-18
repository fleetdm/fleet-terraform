data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

### Trust store and dependencies

resource "aws_lb_trust_store" "this" {

  ca_certificates_bundle_s3_bucket         = module.lb_trust_store_bucket[0].s3_bucket_id
  ca_certificates_bundle_s3_key            = var.alb_config.trust_store.ca_certificates_bundle_s3_key
  ca_certificates_bundle_s3_object_version = var.alb_config.trust_store.ca_certificates_bundle_s3_object_version
  name                                     = "${var.customer_prefix}-trust-store"

}

resource "aws_lb_trust_store_revocation" "this" {
  for_each = var.alb_config.trust_store.create_trust_store_revocation && var.alb_config.trust_store.revocation_lists != null ? var.alb_config.trust_store.revocation_lists : {}

  trust_store_arn               = aws_lb_trust_store.this.arn 
  revocations_s3_bucket         = module.lb_trust_store_bucket[0].s3_bucket_id
  revocations_s3_key            = each.value.revocations_s3_key
  revocations_s3_object_version = each.value.revocations_s3_object_version
}

data "aws_iam_policy_document" "alb_trust_store_restricted" {
  statement {
    sid    = "AllowSpecificALBReadTrustStore"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["elasticloadbalancing.amazonaws.com"]
    }

    actions = ["s3:GetObject"]

    # Specify the exact certificate object ARN
    resources = [
      "${module.lb_trust_store_bucket.s3_bucket_arn}/*"
    ]

    # Restrict to the specific ALB and Account
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.okta_mtls_alb.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

module "lb_trust_store_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.9.1"
    
  bucket = "${var.prefix}-trust-store"
      
  # Allow deletion of non-empty bucket
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
  policy                                = data.aws_iam_policy_document.alb_trust_store_restricted.json
  block_public_acls                     = true
  block_public_policy                   = true
  ignore_public_acls                    = true
  restrict_public_buckets               = true
  acl                                   = "private"
  control_object_ownership              = true
  object_ownership                      = "ObjectWriter"
        
  server_side_encryption_configuration = {
    rule = {
      bucket_key_enabled = true
      apply_server_side_encryption_by_default = {
        sse_algorithm = "aws:kms"
      }
    }
  }
  lifecycle_rule = [
    {
      id      = "trust_store"
      enabled = true

      transition = [
        {
          days          = var.s3_transition_days
          storage_class = "ONEZONE_IA"
        }
      ]
      expiration = {
        days = var.s3_expiration_days
      }
      noncurrent_version_expiration = {
        newer_noncurrent_versions = var.s3_newer_noncurrent_versions
        days                      = var.s3_noncurrent_version_expiration_days
      }
      filter = []
    }
  ]
}

### ALB
module "okta_mtls_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.4.0"

  name = var.alb_config.name

  load_balancer_type = "application"

  vpc_id                     = var.vpc_id
  subnets                    = var.alb_config.subnets
  security_groups            = var.alb_config.security_groups
  access_logs                = var.alb_config.access_logs
  idle_timeout               = var.alb_config.idle_timeout
  internal                   = var.alb_config.internal
  enable_deletion_protection = var.alb_config.enable_deletion_protection

  target_groups = {
    "tg-0" = {
       name              = var.alb_config.name
       backend_protocol  = "HTTP"
       backend_port      = 80
       target_type       = "ip"
       create_attachment = false
       health_check = {
         path                = "/healthz"
         matcher             = "200"
         timeout             = 10
         interval            = 15
         healthy_threshold   = 5
         unhealthy_threshold = 5
       }
    }
  }

  xff_header_processing_mode = var.alb_config.xff_header_processing_mode

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = {
      ssl_policy      = var.alb_config.tls_policy
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = var.alb_config.certificate_arn
      mutual_authentication = {
        mode            = "verify"
        trust_store_arn = module.trust_store.trust_store_arn
      }
      forward = {
        target_group_key = "tg-0"
      }
      routing_http_request_x_amzn_mtls_clientcert_serial_number_header_name = "X-Client-Cert-Serial"
      rules = {
        "https/okta-deny" = {
          actions = [{
            fixed_response = [{
              content_type = "text/plain"
              message_body = "Not Found"
              status_code  = "404"
            }]
            order = 1
            type  = "fixed-response"
          }]
          conditions = [{
            host_header = [{
              regex_values = ["^okta.*"]
            }]
          }]
        }
      }
    }
  }

  tags = {
    Name = var.alb_config.name
  }
}
