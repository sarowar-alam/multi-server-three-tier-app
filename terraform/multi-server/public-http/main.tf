# =============================================================================
#  Case 1c: Multi-server + public IP + plain HTTP
#  Access: http://FRONTEND_PUBLIC_IP
#
#  Architecture:
#    DB       -> private subnet (5432 from backend SG only, NAT for setup)
#    Backend  -> private subnet (3000 from frontend SG only, NAT for setup)
#    Frontend -> public subnet  (80/443 from internet, public IP)
#    No ALB, no certificate, no Route53.
#    Launch order: DB -> Backend (uses DB private IP) -> Frontend (uses Backend private IP)
# =============================================================================

locals {
  scenario    = "multi-server-public-http"
  project     = "bmi-health-tracker"
  common_tags = {
    Project   = local.project
    Scenario  = local.scenario
    ManagedBy = "terraform"
  }
  public_subnet_az    = ["ap-south-1a", "ap-south-1b"]
  public_subnet_cidr  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_az   = ["ap-south-1a", "ap-south-1b"]
  private_subnet_cidr = ["10.0.11.0/24", "10.0.12.0/24"]
}

# ── VPC (NAT required for private instances to reach internet) ────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.common_tags, { Name = "bmi-vpc" })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidr[count.index]
  availability_zone       = local.public_subnet_az[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.common_tags, { Name = "bmi-public-${local.public_subnet_az[count.index]}" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidr[count.index]
  availability_zone = local.private_subnet_az[count.index]
  tags = merge(local.common_tags, { Name = "bmi-private-${local.private_subnet_az[count.index]}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "bmi-igw" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "bmi-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.common_tags, { Name = "bmi-nat-gw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "bmi-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "bmi-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "frontend" {
  name        = "bmi-frontend-sg"
  description = "BMI Frontend: 80/443 from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "bmi-frontend-sg" })
}

resource "aws_security_group" "backend" {
  name        = "bmi-backend-sg"
  description = "BMI Backend: 3000 from frontend SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API from frontend"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "bmi-backend-sg" })
}

resource "aws_security_group" "db" {
  name        = "bmi-db-sg"
  description = "BMI DB: 5432 from backend SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from backend"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "bmi-db-sg" })
}

# ── EC2 instances (DB -> Backend -> Frontend, sequential via IP references) ───

resource "aws_instance" "db" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name != "" ? var.key_name : null
  user_data = templatefile("${path.module}/userdata-db.tftpl", {
    db_password = var.db_password
  })
  root_block_device {
    volume_size = 20; volume_type = "gp3"; delete_on_termination = true
  }
  tags = merge(local.common_tags, { Name = "bmi-db" })
}

resource "aws_instance" "backend" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name != "" ? var.key_name : null
  user_data = templatefile("${path.module}/userdata-backend.tftpl", {
    db_password  = var.db_password
    db_host      = aws_instance.db.private_ip   # implicit dependency on db
    frontend_url = "*"
  })
  root_block_device {
    volume_size = 20; volume_type = "gp3"; delete_on_termination = true
  }
  tags = merge(local.common_tags, { Name = "bmi-backend" })
}

resource "aws_instance" "frontend" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name != "" ? var.key_name : null
  user_data = templatefile("${path.module}/userdata-frontend.tftpl", {
    mode         = "public"
    backend_host = aws_instance.backend.private_ip  # implicit dependency on backend
    domain       = ""
    cert_email   = ""
  })
  root_block_device {
    volume_size = 20; volume_type = "gp3"; delete_on_termination = true
  }
  tags = merge(local.common_tags, { Name = "bmi-frontend" })
}
