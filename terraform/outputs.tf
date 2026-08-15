output "instance_id" { value = aws_instance.satellite.id }
output "private_ip" { value = aws_instance.satellite.private_ip }
output "public_ip" { value = aws_instance.satellite.public_ip }
output "satellite_fqdn" { value = local.satellite_fqdn }
output "pulp_volume_id" { value = aws_ebs_volume.pulp.id }
output "ssm_start_session" { value = "aws ssm start-session --target ${aws_instance.satellite.id} --region ${var.aws_region}" }
