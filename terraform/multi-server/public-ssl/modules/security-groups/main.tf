# ── ALB SG (created only when with_alb = true) ────────────────────────────────
resource "aws_security_group" "alb" {
  count       = var.with_alb ? 1 : 0
  name        = "bmi-alb-sg"
  description = "BMI ALB: 80/443 from internet"
  vpc_id      = var.vpc_id

  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(var.tags, { Name = "bmi-alb-sg" })
}

# ── Frontend / Single-server SG ───────────────────────────────────────────────
# ALB mode  → port 80 from ALB SG only
# Public mode → 80 + 443 from internet
resource "aws_security_group" "frontend" {
  name        = "bmi-frontend-sg"
  description = "BMI Frontend: HTTP inbound"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.with_alb ? [] : [1]
    content {
      description = "HTTP from internet"
      from_port   = 80; to_port = 80; protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "ingress" {
    for_each = var.with_alb ? [] : [1]
    content {
      description = "HTTPS from internet"
      from_port   = 443; to_port = 443; protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "ingress" {
    for_each = var.with_alb ? [1] : []
    content {
      description     = "HTTP from ALB only"
      from_port       = 80; to_port = 80; protocol = "tcp"
      security_groups = [aws_security_group.alb[0].id]
    }
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(var.tags, { Name = "bmi-frontend-sg" })
}

# ── Backend SG (multi-server only) ───────────────────────────────────────────
resource "aws_security_group" "backend" {
  count       = var.is_multi ? 1 : 0
  name        = "bmi-backend-sg"
  description = "BMI Backend: 3000 from frontend SG only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "API from frontend"
    from_port       = 3000; to_port = 3000; protocol = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(var.tags, { Name = "bmi-backend-sg" })
}

# ── DB SG (multi-server only) ─────────────────────────────────────────────────
resource "aws_security_group" "db" {
  count       = var.is_multi ? 1 : 0
  name        = "bmi-db-sg"
  description = "BMI DB: 5432 from backend SG only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from backend"
    from_port       = 5432; to_port = 5432; protocol = "tcp"
    security_groups = [aws_security_group.backend[0].id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(var.tags, { Name = "bmi-db-sg" })
}
