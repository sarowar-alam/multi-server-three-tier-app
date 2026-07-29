variable "vpc_id"   { type = string }
variable "with_alb" { type = bool;         default = false }
variable "is_multi" { type = bool;         default = false }
variable "tags"     { type = map(string);  default = {} }
