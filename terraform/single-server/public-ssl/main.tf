# Case 2b: Single-server + public IP + Let's Encrypt HTTPS
# Access: https://bmi.ostaddevops.click

locals {
  scenario    = "single-server-public-ssl"
  common_tags = {
    Project   = "bmi-health-tracker"
    Scenario  = local.scenario
    ManagedBy = "terraform"
  }  
}

module "vpc" {
    source   = "./modules/vpc"
    with_nat = false
    tags     = local.common_tags
}

module "sg" {
  source   = "./modules/security-groups"
  vpc_id   = module.vpc.vpc_id
  with_alb = false
  is_multi = false
  tags     = local.common_tags
}

module "single" {
  source               = "./modules/ec2"
  name                 = "bmi-single"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.public_subnet_ids[0]
  sg_ids               = [module.sg.sg_frontend_id]
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name
  user_data = templatefile("${path.module}/userdata-single.tftpl", {
    db_password = var.db_password
    mode        = "public"
    domain      = var.domain
    cert_email  = var.cert_email
  })
  tags = local.common_tags
}

module "route53" {
  source  = "./modules/route53"
  zone_id = var.route53_zone_id
  domain  = var.domain
  ip      = module.single.public_ip
}
