output "db_instance_id"       { value = aws_instance.db.id }
output "backend_instance_id"  { value = aws_instance.backend.id }
output "frontend_instance_id" { value = aws_instance.frontend.id }
output "frontend_public_ip"   { value = aws_instance.frontend.public_ip }
output "access_url"           { value = "https://${var.domain}" }
