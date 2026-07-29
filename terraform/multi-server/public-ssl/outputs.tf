output "db_instance_id"       { value = module.db.instance_id }
output "backend_instance_id"  { value = module.backend.instance_id }
output "frontend_instance_id" { value = module.frontend.instance_id }
output "frontend_public_ip"   { value = module.frontend.public_ip }
output "access_url"           { value = "https://${var.domain}" }
