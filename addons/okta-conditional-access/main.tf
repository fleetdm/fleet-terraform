module "trust_store" {
  source = "terraform-aws-modules/alb/aws//modules/lb_trust_store"
  version = "10.4.0"

  name                             = "my-trust-store"
  ca_certificates_bundle_s3_bucket = "my-cert-bucket"
  ca_certificates_bundle_s3_key    = "ca_cert/RootCA.pem"
  create_trust_store_revocation    = true
  revocation_lists = {
    crl_1 = {
      revocations_s3_bucket = "my-cert-bucket"
      revocations_s3_key    = "crl/crl_1.pem"
    }
    crl_2 = {
      revocations_s3_bucket = "my-cert-bucket"
      revocations_s3_key    = "crl/crl_2.pem"
    }
  }
}

module "mtls_albs" {
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
