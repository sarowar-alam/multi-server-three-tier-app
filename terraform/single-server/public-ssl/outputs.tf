output "instance_id" { value = aws_instance.single.id }
output "public_ip"   { value = aws_instance.single.public_ip }
output "access_url"  { value = "https://${var.domain}" }
output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.single.id} --profile sarowar-ostad --region ap-south-1"
}
