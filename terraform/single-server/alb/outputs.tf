output "instance_id" { value = aws_instance.single.id }
output "alb_dns"     { value = aws_lb.main.dns_name }
output "access_url"  { value = "https://${var.domain}" }
output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.single.id} --profile sarowar-ostad --region ap-south-1"
}
