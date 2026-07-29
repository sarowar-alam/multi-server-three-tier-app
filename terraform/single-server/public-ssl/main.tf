# =============================================================================
#  Case 2b: Single-server + public IP + Let's Encrypt HTTPS
#  Access: https://bmi.ostaddevops.click
#
#  Architecture:
#    One EC2 in a public subnet — DB + Backend + Frontend all on one machine.
#    Nginx: HTTP:80 redirects to HTTPS:443 (certbot --redirect).
#    Route53 plain A record: domain -> EC2 public IP.
#    IMPORTANT: Route53 A record is created BEFORE EC2 boots so that
#    certbot's HTTP-01 challenge succeeds during userdata execution.
# =============================================================================

locals {
  scenario    = "single-server-public-ssl"
  project     = "bmi-health-tracker"
  common_tags = {
    Project   = local.project
    Scenario  = local.scenario
    ManagedBy = "terraform"
  }
  public_subnet_az   = ["ap-south-1a", "ap-south-1b"]
  public_subnet_cidr = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ── VPC ───────────────────────────────────────────────────────────────────────

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
  description = "BMI single-server: 80 + 443 from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP (certbot ACME challenge + redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
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
    domain      = var.domain
    cert_email  = var.cert_email
  })

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Route53 record must exist before instance boots so certbot can validate
  depends_on = [aws_route53_record.main]

  tags = merge(local.common_tags, { Name = "bmi-single" })
}

# ── Route53 plain A record → EC2 public IP ────────────────────────────────────
# NOTE: Terraform creates this before the instance boots.
# The instance's public IP is determined at launch; Route53 is updated to that IP.
# This is set with depends_on on the instance so the record uses the actual IP.
# For Let's Encrypt HTTP-01: the instance needs port 80 reachable at this domain.

resource "aws_route53_record" "main" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"
  ttl     = 60
  records = [aws_instance.single.public_ip]
}
