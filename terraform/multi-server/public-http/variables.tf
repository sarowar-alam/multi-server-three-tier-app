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
