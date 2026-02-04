variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  type    = string
  default = "thepuregrace.com"
}

variable "route53_zone_id" {
  type = string
}

variable "s3_bucket" {
  type    = string
  default = "email-thepuregrace-regitros"
}

variable "incoming_prefix" {
  type    = string
  default = "incoming/"
}

variable "allowed_recipients" {
  type = list(string)
  default = [
    "domains@thepuregrace.com",
    "admin@thepuregrace.com",
    "billing@thepuregrace.com"
  ]
}

variable "forward_to" {
  type    = string
  default = "dayvson.red@gmail.com"
}

variable "forward_from" {
  type    = string
  default = "admin@thepuregrace.com"
}

variable "skip_to" {
  type    = string
  default = "dayvson.red@gmail.com"
}
