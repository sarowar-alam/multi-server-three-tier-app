variable "name_prefix" { type = string; default = "bmi" }
variable "vpc_cidr"    { type = string; default = "10.0.0.0/16" }
variable "with_nat"    { type = bool;   default = false }

variable "public_subnets" {
  type = list(object({ cidr = string, az = string }))
  default = [
    { cidr = "10.0.1.0/24",  az = "ap-south-1a" },
    { cidr = "10.0.2.0/24",  az = "ap-south-1b" },
  ]
}

variable "private_subnets" {
  type = list(object({ cidr = string, az = string }))
  default = [
    { cidr = "10.0.11.0/24", az = "ap-south-1a" },
    { cidr = "10.0.12.0/24", az = "ap-south-1b" },
  ]
}

variable "tags" { type = map(string); default = {} }
