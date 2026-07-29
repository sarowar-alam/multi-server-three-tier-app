output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.single.id
}

output "public_ip" {
  description = "EC2 public IP address"
  value       = aws_instance.single.public_ip
}

output "access_url" {
  description = "Application URL (available ~10 min after launch)"
  value       = "http://${aws_instance.single.public_ip}"
}

output "ssm_command" {
  description = "SSM Session Manager connect command"
  value       = "aws ssm start-session --target ${aws_instance.single.id} --profile sarowar-ostad --region ap-south-1"
}
