# Case 2a: Single-server + private subnet + ALB + ACM cert + Route53
# Access: https://bmi.ostaddevops.click

locals {
  scenario    = "single-server-alb"
  common_tags = {
    Project   = "bmi-health-tracker"
    Scenario  = local.scenario
    ManagedBy = "terraform"
  }
}

module "vpc" {
  source   = "./modules/vpc"
  with_nat = true
  tags     = local.common_tags
}

module "sg" {
  source   = "./modules/security-groups"
  vpc_id   = module.vpc.vpc_id
  with_alb = true
  is_multi = false
  tags     = local.common_tags
}

module "single" {
  source               = "./modules/ec2"
  name                 = "bmi-single"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.private_subnet_ids[0]
  sg_ids               = [module.sg.sg_frontend_id]
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name
  user_data = templatefile("${path.module}/userdata-single.tftpl", {
    db_password = var.db_password
    mode        = "alb"
    domain      = ""
    cert_email  = ""
  })
  tags = local.common_tags
}

module "alb" {
  source             = "./modules/alb"
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  sg_id              = module.sg.sg_alb_id
  target_instance_id = module.single.instance_id
  acm_cert_arn       = var.acm_cert_arn
  tags               = local.common_tags
}

module "route53" {
  source      = "./modules/route53"
  zone_id     = var.route53_zone_id
  domain      = var.domain
  is_alias    = true
  alb_dns     = module.alb.alb_dns
  alb_zone_id = module.alb.alb_zone_id
}
