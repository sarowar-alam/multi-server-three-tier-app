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
  type    = string
  default = "bmi.ostaddevops.click"
}

variable "route53_zone_id" {
  type    = string
  default = "Z1019653XLWIJ02C53P5"
}

variable "acm_cert_arn" {
  type    = string
  default = "arn:aws:acm:ap-south-1:388779989543:certificate/9eabfa2b-1b15-4b7a-beed-881e00ffe10d"
}
