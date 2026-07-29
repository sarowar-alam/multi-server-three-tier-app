variable "aws_profile"          { type = string; default = "sarowar-ostad" }
variable "region"               { type = string; default = "ap-south-1" }
variable "ami_id"               { type = string; default = "ami-01a00762f46d584a1" }
variable "instance_type"        { type = string; default = "t3.micro" }
variable "iam_instance_profile" { type = string; default = "SSM" }
variable "key_name"             { type = string; default = "" }

variable "db_password" {
  type      = string
  sensitive = true
}
