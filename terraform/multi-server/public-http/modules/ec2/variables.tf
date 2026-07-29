variable "name"                 { type = string }
variable "ami_id"               { type = string }
variable "instance_type"        { type = string }
variable "subnet_id"            { type = string }
variable "sg_ids"               { type = list(string) }
variable "iam_instance_profile" { type = string }
variable "user_data"            { type = string }
variable "key_name"             { type = string; default = "" }
variable "volume_size"          { type = number; default = 20 }
variable "tags"                 { type = map(string); default = {} }
