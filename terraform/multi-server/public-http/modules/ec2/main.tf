resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.sg_ids
  iam_instance_profile   = var.iam_instance_profile
  user_data              = var.user_data
  key_name               = var.key_name != "" ? var.key_name : null

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = var.name })
}
