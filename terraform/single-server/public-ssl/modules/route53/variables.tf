variable "zone_id"     { type = string }
variable "domain"      { type = string }
variable "is_alias"    { type = bool;   default = false }
variable "alb_dns"     { type = string; default = "" }
variable "alb_zone_id" { type = string; default = "" }
variable "ip"          { type = string; default = "" }
variable "ttl"         { type = number; default = 60 }
