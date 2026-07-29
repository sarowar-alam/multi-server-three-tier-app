variable "name" {
  type    = string
  default = "bmi-alb"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "sg_id" {
  type = string
}

variable "target_instance_id" {
  type = string
}

variable "acm_cert_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
