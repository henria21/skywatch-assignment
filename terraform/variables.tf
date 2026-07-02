variable "region"        { default = "eu-west-1" }
variable "key_name"      { default = "skywatch-key" }
variable "ssh_private_key_path" { default = "~/.ssh/skywatch-key.pem" }

# Per-node instance type. Default micro everywhere (free tier).
variable "instance_types" {
  type = map(string)
  default = {
    master   = "t3.small"
    worker   = "t3.micro"
    worker2  = "t3.small"
  }
}

variable "my_ip_cidr" {
  description = "Your public IP /32 for SSH + NodePort access"
  type        = string
}
