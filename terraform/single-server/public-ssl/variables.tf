variable "aws_profile"          { type = string; default = "sarowar-ostad" }
variable "region"               { type = string; default = "ap-south-1" }
variable "ami_id"               { type = string; default = "ami-01a00762f46d584a1" }
variable "instance_type"        { type = string; default = "t3.micro" }
variable "iam_instance_profile" { type = string; default = "SSM" }
variable "key_name"             { type = string; default = "" }

variable "db_password" {
  description = "PostgreSQL bmi_user password"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Public domain for Let's Encrypt HTTPS (e.g. bmi.ostaddevops.click)"
  type        = string
  default     = "bmi.ostaddevops.click"
}

variable "cert_email" {
  description = "Let's Encrypt registration email"
  type        = string
  default     = "admin@ostaddevops.click"
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
  default     = "Z1019653XLWIJ02C53P5"
}
