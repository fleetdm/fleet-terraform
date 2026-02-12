resource "aws_s3_bucket" "destination" {
  provider      = aws.target
  bucket        = var.s3.bucket_name
  force_destroy = var.s3.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "destination" {
  provider                = aws.target
  bucket                  = aws_s3_bucket.destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  provider = aws.target
  bucket   = aws_s3_bucket.destination.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
