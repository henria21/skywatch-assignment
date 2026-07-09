# 03 — Terraform (AWS infrastructure)

**Goal:** three t3.small EC2 nodes + security group, with the Ansible inventory written
automatically.
**Prereqts:** AWS account, AWS CLI configured, an EC2 key pair `skywatch-key` with the private key at
`~/.ssh/skywatch-key.pem`.
**Done when:** `terraform apply` brings up 3 instances and writes `../ansible/inventory.ini`; all 3
are reachable over SSH.

> **Cost note:** t3.small is ~$0.023/hr per node. 3 nodes × ~10 h/session ≈ $0.69/session.
> **Destroy after every session** (`terraform destroy`). t3.micro OOMs under kube-prometheus-stack
> load; t3.small (2 GiB RAM) is the minimum viable size for this stack.

---

## Repo layout

```
terraform/
  main.tf
  variables.tf
  outputs.tf
  inventory.tmpl
  terraform.tfvars        # gitignored — never commit
  .gitignore
```

`.gitignore`:
```
terraform.tfstate*
terraform.tfvars
.terraform/
```

## Step 1 — `variables.tf`

```hcl
variable "region"        { default = "eu-west-1" }
variable "key_name"      { default = "skywatch-key" }
variable "ssh_private_key_path" { default = "~/.ssh/skywatch-key.pem" }

# Per-node instance type. Default micro everywhere (free tier).
variable "instance_types" {
  type = map(string)
  default = {
    master   = "t3.small"
    worker   = "t3.small"
    worker2  = "t3.small"
  }
}

variable "my_ip_cidr" {
  description = "Your public IP /32 for SSH + NodePort access"
  type        = string
}
```

`terraform.tfvars` (gitignored):
```hcl
my_ip_cidr = "X.X.X.X/32"   # your current public IP
```

## Step 2 — `main.tf`

```hcl
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
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # K3s API
    from_port = 6443
    to_port   = 6443
    protocol  = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # NodePort range
    from_port = 30000
    to_port   = 32767
    protocol  = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress { # intra-cluster: SG references itself
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "node" {
  for_each      = var.instance_types
  ami           = data.aws_ami.ubuntu.id
  instance_type = each.value
  key_name      = var.key_name
  vpc_security_group_ids = [aws_security_group.skywatch.id]
  tags = { Name = "skywatch-${each.key}" }
}

# Render the Ansible inventory from a template
resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = templatefile("${path.module}/inventory.tmpl", {
    master_public   = aws_instance.node["master"].public_ip
    master_private  = aws_instance.node["master"].private_ip
    worker_public   = aws_instance.node["worker"].public_ip
    worker2_public  = aws_instance.node["worker2"].public_ip
    ssh_key         = var.ssh_private_key_path
  })
}
```

## Step 3 — `inventory.tmpl`

The worker plays need the master's **private** IP (intra-VPC traffic via the SG self-rule; the public
IP would egress through the IGW and bypass the rule, making 6443 look closed).

```ini
[master]
${master_public} node_role=master master_private_ip=${master_private}

[workers]
${worker_public}  node_role=worker
${worker2_public} node_role=worker2

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${ssh_key}
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
master_private_ip=${master_private}
```

## Step 4 — `outputs.tf`

```hcl
output "master_public_ip"  { value = aws_instance.node["master"].public_ip }
output "worker2_public_ip" { value = aws_instance.node["worker2"].public_ip }
```

## Optional improvement — remote state on S3 instead of local `terraform.tfstate`
Currently state lives as a local file (gitignored, see top of this doc). An S3 backend is the
production-grade alternative:

```hcl
terraform {
  backend "s3" {
    bucket         = "skywatch-tfstate-<account-id>"   # must exist before terraform init
    key            = "skywatch/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "skywatch-tfstate-lock"           # optional: state locking
  }
}
```
Migrate existing state with `terraform init -migrate-state` (Terraform copies the local state up).

Benefits over the local file:
- **Can't lose it / can't leak it** — today the state (which contains resource IDs and any secrets
  in outputs) exists only on one laptop; a disk wipe orphans the whole cluster, and the only thing
  keeping it out of git is `.gitignore`. S3 + `encrypt = true` removes both risks.
- **Team / multi-machine access** — anyone (or CI) with AWS credentials can `plan`/`apply`; no
  more "the state is on the other machine".
- **Locking** — with the DynamoDB table, two concurrent `apply` runs can't corrupt state.
- **Versioning** — enable S3 bucket versioning and every state revision is recoverable; local
  files have only the single `.backup`.

Cost is effectively zero (KB-sized object). Trade-off: a chicken-and-egg bucket that must be
created outside this Terraform config (console, CLI, or a separate tiny bootstrap config), and
teardown order matters — destroy the cluster before deleting the bucket.

## Done when

```bash
cd terraform && terraform init && terraform apply -auto-approve
cat ../ansible/inventory.ini          # has 3 real IPs
ssh -i ~/.ssh/skywatch-key.pem ubuntu@$(terraform output -raw master_public_ip) hostname
```
All three SSH-reachable. Teardown when finished: `terraform destroy -auto-approve`.
