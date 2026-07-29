# Case 1c: Multi-server + public IP + plain HTTP
# Access: http://FRONTEND_PUBLIC_IP

locals {
  scenario    = "multi-server-public-http"
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
  with_alb = false
  is_multi = true
  tags     = local.common_tags
}

module "db" {
  source               = "./modules/ec2"
  name                 = "bmi-db"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.private_subnet_ids[0]
  sg_ids               = [module.sg.sg_db_id]
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name
  user_data = templatefile("${path.module}/userdata-db.tftpl", { db_password = var.db_password })
  depends_on = [module.vpc]
  tags       = local.common_tags
}

module "backend" {
  source               = "./modules/ec2"
  name                 = "bmi-backend"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.private_subnet_ids[0]
  sg_ids               = [module.sg.sg_backend_id]
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name
  user_data = templatefile("${path.module}/userdata-backend.tftpl", {
    db_password  = var.db_password
    db_host      = module.db.private_ip
    frontend_url = "*"
  })
  depends_on = [module.vpc]
  tags       = local.common_tags
}

module "frontend" {
  source               = "./modules/ec2"
  name                 = "bmi-frontend"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.public_subnet_ids[0]
  sg_ids               = [module.sg.sg_frontend_id]
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name
  user_data = templatefile("${path.module}/userdata-frontend.tftpl", {
    mode         = "public"
    backend_host = module.backend.private_ip
    domain       = ""
    cert_email   = ""
  })
  tags = local.common_tags
}
