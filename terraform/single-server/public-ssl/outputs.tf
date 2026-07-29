output "instance_id" { value = module.single.instance_id }
output "public_ip"   { value = module.single.public_ip }
output "access_url"  { value = "https://${var.domain}" }
output "ssm_command" {
  value = "aws ssm start-session --target ${module.single.instance_id} --profile sarowar-ostad --region ap-south-1"
}
