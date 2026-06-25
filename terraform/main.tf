terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

# Dynamic Ubuntu 22.04 AMI lookup (no hard-coded AMI id)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" { default = true }

resource "aws_security_group" "skywatch" {
  name        = "skywatch-sg"
  description = "SkyWatch cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress { # SSH
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # K3s API
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # NodePort range
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # intra-cluster: SG references itself
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "node" {
  for_each               = var.instance_types
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.skywatch.id]
  tags = { Name = "skywatch-${each.key}" }
}

# Render the Ansible inventory from a template
resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = templatefile("${path.module}/inventory.tmpl", {
    master_public  = aws_instance.node["master"].public_ip
    master_private = aws_instance.node["master"].private_ip
    worker_public  = aws_instance.node["worker"].public_ip
    worker2_public = aws_instance.node["worker2"].public_ip
    ssh_key        = var.ssh_private_key_path
  })
}
