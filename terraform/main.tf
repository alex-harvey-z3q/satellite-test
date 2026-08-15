locals {
  satellite_fqdn = coalesce(
    var.satellite_fqdn,
    format("ip-%s.%s.compute.internal", replace(aws_instance.satellite.private_ip, ".", "-"), var.aws_region),
  )
}

resource "aws_iam_role" "ssm" {
  name = "${var.name_prefix}-ssm"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.name_prefix}-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_security_group" "satellite" {
  name_prefix = "${var.name_prefix}-"
  description = "Satellite POC access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Satellite web UI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  dynamic "ingress" {
    for_each = length(var.ssh_cidrs) > 0 ? [1] : []
    content {
      description = "Ansible SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidrs
    }
  }

  egress {
    description = "RHEL, Red Hat CDN, SSM, and time services"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "satellite" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids      = [aws_security_group.satellite.id]
  associate_public_ip_address = var.associate_public_ip_address
  monitoring                  = true
  ebs_optimized               = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, { Name = var.name_prefix, Role = "satellite" })
}

resource "aws_ebs_volume" "pulp" {
  availability_zone = aws_instance.satellite.availability_zone
  size              = var.pulp_volume_size_gib
  type              = var.pulp_volume_type
  iops              = var.pulp_iops
  throughput        = var.pulp_throughput
  encrypted         = true
  tags              = merge(var.tags, { Name = "${var.name_prefix}-pulp" })
}

resource "aws_volume_attachment" "pulp" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.pulp.id
  instance_id = aws_instance.satellite.id
}

resource "aws_route53_record" "satellite" {
  count   = var.hosted_zone_id == null ? 0 : 1
  zone_id = var.hosted_zone_id
  name    = var.satellite_fqdn
  type    = "A"
  ttl     = 300
  records = [var.associate_public_ip_address ? aws_instance.satellite.public_ip : aws_instance.satellite.private_ip]
}
