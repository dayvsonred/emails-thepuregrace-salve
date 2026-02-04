output "ses_domain_verification_token" {
  value = aws_ses_domain_identity.domain.verification_token
}

output "ses_dkim_tokens" {
  value = aws_ses_domain_dkim.dkim.dkim_tokens
}

output "ses_receipt_rule_set" {
  value = aws_ses_receipt_rule_set.main.rule_set_name
}

output "s3_bucket" {
  value = aws_s3_bucket.email.id
}
