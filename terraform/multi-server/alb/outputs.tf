output "db_instance_id"       { value = module.db.instance_id }
output "backend_instance_id"  { value = module.backend.instance_id }
output "frontend_instance_id" { value = module.frontend.instance_id }
output "alb_dns"              { value = module.alb.alb_dns }
output "access_url"           { value = "https://${var.domain}" }
