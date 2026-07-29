output "db_instance_id"       { value = aws_instance.db.id }
output "backend_instance_id"  { value = aws_instance.backend.id }
output "frontend_instance_id" { value = aws_instance.frontend.id }
output "alb_dns"              { value = aws_lb.main.dns_name }
output "access_url"           { value = "https://${var.domain}" }
