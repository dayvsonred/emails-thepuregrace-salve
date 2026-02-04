terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --------------------
# S3
# --------------------
resource "aws_s3_bucket" "email" {
  bucket = var.s3_bucket
}

resource "aws_s3_bucket_public_access_block" "email" {
  bucket                  = aws_s3_bucket.email.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "email" {
  bucket = aws_s3_bucket.email.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Permitir SES gravar no bucket
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_policy" "ses_put" {
  bucket = aws_s3_bucket.email.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "AllowSESPutObject",
        Effect = "Allow",
        Principal = { Service = "ses.amazonaws.com" },
        Action = "s3:PutObject",
        Resource = "${aws_s3_bucket.email.arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# --------------------
# SES - Domínio
# --------------------
resource "aws_ses_domain_identity" "domain" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "dkim" {
  domain = aws_ses_domain_identity.domain.domain
}

# --------------------
# Route 53 - DNS
# --------------------
resource "aws_route53_record" "ses_verification" {
  zone_id = var.route53_zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.domain.verification_token]
}

resource "aws_route53_record" "dkim" {
  zone_id = var.route53_zone_id
  name    = "${aws_ses_domain_dkim.dkim.dkim_tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.dkim.dkim_tokens[count.index]}.dkim.amazonses.com"]
  count   = 3
}

resource "aws_route53_record" "mx" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 600
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

resource "aws_route53_record" "spf" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

# --------------------
# Lambda
# --------------------
resource "aws_iam_role" "lambda" {
  name = "ses-store-email-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = "${aws_s3_bucket.email.arn}/*"
      },
      {
        Effect = "Allow",
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ],
        Resource = [
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.domain}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/admin@${var.domain}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/domains@${var.domain}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/billing@${var.domain}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/dayvson.red@gmail.com"
        ]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/ses-store-email"
  retention_in_days = 14
}

resource "aws_lambda_function" "store_email" {
  function_name = "ses-store-email"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BUCKET             = var.s3_bucket
      INCOMING_PREFIX    = var.incoming_prefix
      DELETE_SOURCE      = "false"
      ALLOWED_RECIPIENTS = join(",", var.allowed_recipients)
      FORWARD_TO         = var.forward_to
      FORWARD_FROM       = var.forward_from
      SKIP_TO            = var.skip_to
    }
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/emails_thegracepure_salve/lambda"
  output_path = "${path.module}/emails_thegracepure_salve/lambda_store_email.zip"
}

# Permitir SES invocar Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3ToInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.store_email.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.email.arn
}

# --------------------
# SES Receipt Rules
# --------------------
resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "email-receipt-rules"
}

resource "aws_ses_active_receipt_rule_set" "active" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "store_email" {
  name          = "store-in-s3-and-organize"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  enabled       = true
  scan_enabled  = true

  recipients = var.allowed_recipients

  # 1) Salvar email bruto no S3 com key = incoming/<message-id>
  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.email.id
    object_key_prefix = var.incoming_prefix
  }

  depends_on = [
    aws_s3_bucket_policy.ses_put
  ]
}

resource "aws_s3_bucket_notification" "incoming_lambda" {
  bucket = aws_s3_bucket.email.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.store_email.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = var.incoming_prefix
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

