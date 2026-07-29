resource "aws_route53_record" "alias" {
  count   = var.is_alias ? 1 : 0
  zone_id = var.zone_id
  name    = var.domain
  type    = "A"
  alias {
    name                   = var.alb_dns
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "plain_a" {
  count   = var.is_alias ? 0 : 1
  zone_id = var.zone_id
  name    = var.domain
  type    = "A"
  ttl     = var.ttl
  records = [var.ip]
}
