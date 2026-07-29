output "sg_alb_id"      { value = var.with_alb ? aws_security_group.alb[0].id     : "" }
output "sg_frontend_id" { value = aws_security_group.frontend.id }
output "sg_backend_id"  { value = var.is_multi  ? aws_security_group.backend[0].id : "" }
output "sg_db_id"       { value = var.is_multi  ? aws_security_group.db[0].id      : "" }
