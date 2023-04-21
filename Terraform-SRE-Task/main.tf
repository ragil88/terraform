# Version Block
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0.0"
    }
  }
}
# Variables
variable "vpc_cidr" {
  type    = string
  default = "10.161.0.0/24"
}

variable "subnet_cidrs" {
  type    = list(any)
  default = ["10.161.0.0/26", "10.161.0.64/26", "10.161.0.128/26"]
}

variable "instance_count" {
  type    = number
  default = 3
}

# Data Sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }
}

# Create the VPC
resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr
}
# Create the Subnet
resource "aws_subnet" "subnets" {
  count             = length(var.subnet_cidrs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = element(var.subnet_cidrs, count.index)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
}

# Create an internet gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}


# Create a route table
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.vpc.id

  # Route all traffic to the internet gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Associate the route table with the subnets
resource "aws_route_table_association" "rtb_association" {
  count          = length(var.subnet_cidrs)
  subnet_id      = element(aws_subnet.subnets.*.id, count.index)
  route_table_id = aws_route_table.rtb.id
}

# Generate ssh key pair
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "ssh_key"
  public_key = tls_private_key.ssh_key.public_key_openssh
}

data "aws_key_pair" "ssh_key" {
  key_name = aws_key_pair.ssh_key.key_name
}

# To download the private key to the terraform execution directory.

# When executing from Linux machines unhash blow lines and hash the windows section
/*
resource "null_resource" "download_ssh_key" {
  provisioner "local-exec" {
    command = "echo '${tls_private_key.ssh_key.private_key_pem}' > ssh_key.pem"
  }
}
*/

# When executing from Windows machines.
resource "null_resource" "download_ssh_key" {
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "Set-Content -Path ssh_key.pem -Value '${tls_private_key.ssh_key.private_key_pem}'"
  }
}


# Create a security group for the ALB & Instances
resource "aws_security_group" "lb_sg" {
  name        = "lb-sg"
  description = "Security group for the ALB"
  vpc_id      = aws_vpc.vpc.id

  # Allow inbound traffic from anywhere on port 80
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  #Allow inbound traffic from anywhere on port 22
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound traffic to anywhere on any port
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Set host names for the instances
# for linux
/*
data "template_file" "user_data" {
  count = var.instance_count
  template = file("${path.module}/user_data.tpl")  // Use absolute path here
  vars = {
    hostname = "server${count.index + 1}"
  }
}
*/

# for windows
data "template_file" "user_data" {
  count = var.instance_count
  template = file("${path.module}\\user_data.tpl")
  vars = {
    hostname = "server${count.index + 1}"
  }
}
# Create instances
resource "aws_instance" "instances" {
  count         = var.instance_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.subnets.*.id, count.index)
  key_name      = "ssh_key"
  user_data     = data.template_file.user_data[count.index].rendered
  iam_instance_profile = aws_iam_instance_profile.awsiaminstanceprofile.name
  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.ssh_key.private_key_pem
    host        = self.public_ip
  }


  depends_on = [null_resource.download_ssh_key]


  # add this argument to associate the security group with the instances
  vpc_security_group_ids = [aws_security_group.lb_sg.id]


  # use file provisioner to copy ansible script & jinja2 template to remote instances.

  provisioner "file" {
    source      = "./script.yml"
    destination = "/tmp/script.yml"
  }

  provisioner "file" {
    source      = "./index.j2"
    destination = "/tmp/index.j2"
  }

  # Run a remote-exec provisioner to install Docker & Nginx using Ansible. 
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install ansible -y",
      "sudo apt install python-pip -y",
      "sudo -H pip install docker-py",
      "sudo apt-get install -f",
      "sudo chmod +x /tmp/script.yml",
      "$(which ansible-playbook) /tmp/script.yml -i localhost --ssh-common-args='-o StrictHostKeyChecking=no'",
      #"$(which ansible-playbook) /tmp/script.yml -i ${self.public_ip} --ssh-common-args='-o StrictHostKeyChecking=no'",
    ]

    # wait for 60 seconds before trying to connect
    # try 3 times with 10 seconds interval if connection fails
    connection {
      timeout   = "2m"
      retryable = true
      retries   = 3
      interval  = 10
      delay     = "60s"

    }

  }
  associate_public_ip_address = true
}


# Create an ALB
resource "aws_lb" "alb" {
  name               = "my-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.subnets.*.id
  security_groups    = [aws_security_group.lb_sg.id]
}

# Create a listener for port 80
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  # Forward requests to the target groups based on path pattern
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.default.arn
  }
}

# Create target groups for each EC2 instance
resource "aws_lb_target_group" "default" {
  name     = "default"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id
}

# Attach the EC2 instances to the target groups
resource "aws_lb_target_group_attachment" "instances" {
  count            = var.instance_count
  target_group_arn = aws_lb_target_group.default.arn
  target_id        = element(aws_instance.instances.*.id, count.index)
}

