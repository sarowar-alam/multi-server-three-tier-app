# =============================================================================
#  Case 2c: Single-server + public IP + plain HTTP
#  Access: http://PUBLIC_IP
#
#  Architecture:
#    One EC2 in a public subnet — DB + Backend + Frontend all on one machine.
#    No ALB, no certificate, no Route53.
#    Nginx serves HTTP:80 only.
# =============================================================================

locals {
  scenario    = "single-server-public-http"
  project     = "bmi-health-tracker"
  common_tags = {
    Project     = local.project
    Scenario    = local.scenario
    ManagedBy   = "terraform"
  }

  # VPC CIDR blocks
  vpc_cidr         = "10.0.0.0/16"
  public_subnet_az = ["ap-south-1a", "ap-south-1b"]
  public_subnet_cidr = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
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

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "bmi-igw" })
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

# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "single" {
  name        = "bmi-single-sg"
  description = "BMI single-server: HTTP/HTTPS from internet, all outbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "All outbound (apt, npm, git, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "bmi-single-sg" })
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "single" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.single.id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name != "" ? var.key_name : null

  user_data = templatefile("${path.module}/userdata-single.tftpl", {
    db_password = var.db_password
    mode        = "public"
    domain      = ""
    cert_email  = ""
  })

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "bmi-single" })
}
