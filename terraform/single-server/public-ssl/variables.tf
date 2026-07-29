variable "aws_profile" {
  type    = string
  default = "sarowar-ostad"
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "ami_id" {
  description = "Ubuntu 26.04 LTS amd64 AMI (ap-south-1)"
  type        = string
  default     = "ami-01a00762f46d584a1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "iam_instance_profile" {
  type    = string
  default = "SSM"
}

variable "key_name" {
  description = "EC2 key pair name for SSH (optional; SSM is primary access method)"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "PostgreSQL bmi_user password"
  type        = string
  sensitive   = true
}
variable "domain" {
  description = "Public domain for HTTPS (e.g. bmi.ostaddevops.click)"
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
