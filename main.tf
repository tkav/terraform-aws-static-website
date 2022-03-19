## Providers definition

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.6.0"
    }
  }
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}


resource "aws_s3_bucket" "website_logs" {
  bucket = "${var.website_domain_main}-logs"

  force_destroy = true
}

resource "aws_s3_bucket_acl" "website_logs" {
  bucket = aws_s3_bucket.website_logs.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket" "website_root" {
  bucket = "${var.website_domain_main}-root"

  force_destroy = true
}

resource "aws_s3_bucket_acl" "website_root" {
  bucket = aws_s3_bucket.website_root.id
  acl    = "public-read"
}

resource "aws_s3_bucket_website_configuration" "website_root" {
  bucket = aws_s3_bucket.website_root.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }

}

resource "aws_s3_bucket_logging" "website_root" {
  bucket = aws_s3_bucket.website_root.id

  target_bucket = aws_s3_bucket.website_logs.id
  target_prefix = "${var.website_domain_main}/"
}

resource "aws_s3_bucket_policy" "update_website_root_bucket_policy" {
  bucket = aws_s3_bucket.website_root.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "PolicyForWebsiteEndpointsPublicContent",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": [
        "${aws_s3_bucket.website_root.arn}/*",
        "${aws_s3_bucket.website_root.arn}"
      ]
    }
  ]
}
POLICY
}

resource "aws_cloudfront_origin_access_identity" "website_origin_identity" {
}

resource "aws_acm_certificate" "wildcard_website" {
  provider                  = aws.us-east-1
  domain_name               = var.website_domain_main
  subject_alternative_names = ["*.${var.website_domain_main}"]
  validation_method         = "EMAIL"
}

# Triggers the ACM wildcard certificate validation event
resource "aws_acm_certificate_validation" "wildcard_cert" {
  provider        = aws.us-east-1
  certificate_arn = aws_acm_certificate.wildcard_website.arn
  #validation_record_fqdns = [var.website_domain_main]
}

# Get the ARN of the issued certificate
data "aws_acm_certificate" "wildcard_website" {
  provider = aws.us-east-1

  depends_on = [
    aws_acm_certificate.wildcard_website,
    aws_acm_certificate_validation.wildcard_cert,
  ]

  domain      = var.website_domain_main
  statuses    = ["ISSUED"]
  most_recent = true
}

## CloudFront
# Creates the CloudFront distribution to serve the static website
resource "aws_cloudfront_distribution" "website_cdn_root" {
  enabled     = true
  price_class = "PriceClass_All"
  # Select the correct PriceClass depending on who the CDN is supposed to serve (https://docs.aws.amazon.com/AmazonCloudFront/ladev/DeveloperGuide/PriceClass.html)

  aliases = [var.website_domain_main]

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.website_root.id}"
    domain_name = aws_s3_bucket.website_root.website_endpoint

    custom_origin_config {
      origin_protocol_policy = "http-only"
      # The protocol policy that you want CloudFront to use when fetching objects from the origin server (a.k.a S3 in our situation). HTTP Only is the default setting when the origin is an Amazon S3 static website hosting endpoint, because Amazon S3 doesn’t support HTTPS connections for static website hosting endpoints.
      http_port            = 80
      https_port           = 443
      origin_ssl_protocols = ["TLSv1.2", "TLSv1.1", "TLSv1"]
    }
  }

  default_root_object = "index.html"

  logging_config {
    bucket = aws_s3_bucket.website_logs.bucket_domain_name
    prefix = "${var.website_domain_main}/"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "origin-bucket-${aws_s3_bucket.website_root.id}"
    min_ttl          = "0"
    default_ttl      = "300"
    max_ttl          = "1200"

    viewer_protocol_policy = "redirect-to-https" # Redirects any HTTP request to HTTPS
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = data.aws_acm_certificate.wildcard_website.arn
    ssl_support_method  = "sni-only"
  }

  custom_error_response {
    error_caching_min_ttl = 300
    error_code            = 404
    response_page_path    = "/404.html"
    response_code         = 404
  }

}
