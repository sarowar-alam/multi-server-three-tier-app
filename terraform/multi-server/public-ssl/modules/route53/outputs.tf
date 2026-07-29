output "fqdn" {
  value = var.is_alias ? aws_route53_record.alias[0].fqdn : aws_route53_record.plain_a[0].fqdn
}
