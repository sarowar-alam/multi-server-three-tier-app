# =============================================================================
#  Case 2a: Single-server + private subnet + ALB + ACM cert + Route53
#  Access: https://bmi.ostaddevops.click
#
#  Architecture:
#    EC2 in private subnet — DB + Backend + Frontend all on one machine.
#    NAT Gateway: private instance needs internet for apt/npm/git during setup.
#    ALB in public subnets: terminates HTTPS with ACM certificate.
#    Listener 80:  HTTP 301 redirect to HTTPS.
#    Listener 443: ACM cert + forward to EC2 port 80.
#    Route53 alias A record: domain -> ALB.
# =============================================================================

locals {
  scenario    = "single-server-alb"
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

resource "aws_security_group" "alb" {
  name        = "bmi-alb-sg"
  description = "BMI ALB: 80/443 from internet"
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
  tags = merge(local.common_tags, { Name = "bmi-alb-sg" })
}

resource "aws_security_group" "single" {
  name        = "bmi-single-sg"
  description = "BMI single-server: port 80 from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "bmi-single-sg" })
}

# ── EC2 instance (private subnet) ────────────────────────────────────────────

resource "aws_instance" "single" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.single.id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name != "" ? var.key_name : null

  user_data = templatefile("${path.module}/userdata-single.tftpl", {
    db_password = var.db_password
    mode        = "alb"
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

# ── ALB ───────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "bmi-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = merge(local.common_tags, { Name = "bmi-alb" })
}

resource "aws_lb_target_group" "main" {
  name     = "bmi-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }
  tags = merge(local.common_tags, { Name = "bmi-tg" })
}

resource "aws_lb_target_group_attachment" "single" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.single.id
  port             = 80
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── Route53 alias A record → ALB ─────────────────────────────────────────────

resource "aws_route53_record" "main" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
