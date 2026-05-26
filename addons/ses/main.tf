locals {
  spf_domains = compact(concat([
    aws_ses_domain_identity.default.domain,
    "_amazonses.${aws_ses_domain_identity.default.domain}",
    var.custom_mail_from.enabled == true ? "${var.custom_mail_from.domain_prefix}.${aws_ses_domain_identity.default.domain}" : null
  ]))
  dmarc_domain = "_dmarc.${aws_ses_domain_identity.default.domain}"

  # Most SES regions use dkim.amazonses.com, but AWS documents a small set of
  # region-specific DKIM domains that must be used instead:
  # https://docs.aws.amazon.com/general/latest/gr/ses.html#ses_dkim_domains
  ses_dkim_domains = {
    af-south-1     = "dkim.af-south-1.amazonses.com"
    ap-northeast-3 = "dkim.ap-northeast-3.amazonses.com"
    ap-south-2     = "dkim.ap-south-2.amazonses.com"
    ap-southeast-3 = "dkim.ap-southeast-3.amazonses.com"
    ap-southeast-5 = "dkim.ap-southeast-5.amazonses.com"
    ca-west-1      = "dkim.ca-west-1.amazonses.com"
    eu-central-2   = "dkim.eu-central-2.amazonses.com"
    eu-south-1     = "dkim.eu-south-1.amazonses.com"
    il-central-1   = "dkim.il-central-1.amazonses.com"
    me-central-1   = "dkim.me-central-1.amazonses.com"
    us-gov-east-1  = "dkim.us-gov-east-1.amazonses.com"
  }
  dkim_domain = lookup(local.ses_dkim_domains, data.aws_region.current.region, "dkim.amazonses.com")
}

data "aws_region" "current" {}

resource "aws_ses_domain_identity" "default" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "default" {
  domain = aws_ses_domain_identity.default.domain
}

### CUSTOM MAIL FROM SETTINGS ###

resource "aws_ses_domain_mail_from" "default" {
  count            = var.custom_mail_from.enabled == true ? 1 : 0
  domain           = aws_ses_domain_identity.default.domain
  mail_from_domain = "${var.custom_mail_from.domain_prefix}.${aws_ses_domain_identity.default.domain}"
}

resource "aws_route53_record" "mx_record" {
  count   = var.custom_mail_from.enabled == true ? 1 : 0
  zone_id = var.zone_id
  name    = aws_ses_domain_mail_from.default[count.index].mail_from_domain
  type    = "MX"
  ttl     = "600"
  records = ["10 feedback-smtp.${data.aws_region.current.region}.amazonses.com"]
}

###DKIM VERIFICATION#######

resource "aws_route53_record" "amazonses_dkim_record" {
  count   = 3 // no clue why this is three, but multiple modules all did the same thing
  zone_id = var.zone_id
  name    = "${element(aws_ses_domain_dkim.default.dkim_tokens, count.index)}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${element(aws_ses_domain_dkim.default.dkim_tokens, count.index)}.${local.dkim_domain}"]
}

resource "aws_route53_record" "spf_domain" {
  for_each = toset(local.spf_domains)
  zone_id  = var.zone_id
  name     = each.key
  type     = "TXT"
  ttl      = "600"
  records  = each.key == aws_ses_domain_identity.default.domain ? flatten([["v=spf1 include:amazonses.com -all"], var.extra_txt_records]) : ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "dmarc_domain" {
  zone_id = var.zone_id
  name    = local.dmarc_domain
  type    = "TXT"
  ttl     = "600"
  records = ["v=DMARC1; p=none;"]
}

resource "aws_iam_policy" "main" {
  count  = var.create_iam_policy ? 1 : 0
  policy = data.aws_iam_policy_document.main[0].json
}

data "aws_iam_policy_document" "main" {
  count = var.create_iam_policy ? 1 : 0
  statement {
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values = [
        "*@${var.domain}"
      ]
    }
  }
}
