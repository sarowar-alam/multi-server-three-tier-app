variable "aws_profile" {
  description = "AWS named profile"
  type        = string
  default     = "sarowar-ostad"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "ami_id" {
  description = "Ubuntu 26.04 LTS amd64 AMI (ap-south-1)"
  type        = string
  default     = "ami-01a00762f46d584a1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "iam_instance_profile" {
  description = "IAM instance profile name (must already exist)"
  type        = string
  default     = "SSM"
}

variable "db_password" {
  description = "PostgreSQL bmi_user password"
  type        = string
  sensitive   = true
}

variable "key_name" {
  description = "EC2 key pair name for SSH (optional; SSM is primary access)"
  type        = string
  default     = ""
}
