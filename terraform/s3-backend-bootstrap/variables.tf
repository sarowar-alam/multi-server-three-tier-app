variable "aws_profile" { type = string; default = "sarowar-ostad" }
variable "region"      { type = string; default = "ap-south-1" }

variable "bucket_name" {
  type    = string
  default = "bmi-health-tracker-tfstate"
}
