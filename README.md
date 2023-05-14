



## **Requirements**

| |                                                    |
|-|----------------------------------------------------|
|1| Use Terraform as IaaC to create the infrastructure.|
|2| Use Ansible to configure host services.            |


## **Steps**

* Version and variables for AWS VPC and Subnets.

Below code defines the Terraform version and required AWS provider version. It also declares variables for VPC and subnet and the number of instances as well. 



```terraform
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
```

* Configuration for AWS VPC, Subnets, Internet Gateway, and Route Table

Below code creates an AWS VPC, subnets, internet gateway, and route table. It also uses data sources to get the details of availability zones and an Ubuntu (AMI). The internet gateway is associated with the VPC, and a route table is created to route all traffic to the internet gateway. and the route table is associated with the subnets.

```terraform
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

# Network Resources
resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr
}

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

```

* Generating and Downloading an SSH Key Pair in Terraform

Below code defines the resources required to generate an RSA 4096-bit SSH key pair and download the private key to the Terraform execution directory. 

_Note: The provisioner commands differ for Windows and Linux machines, I used a Windows machine to create and execute the scripts, hence Linux blocks are commented._




```terraform
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

# When executing from Linux machines uncomment the below lines and 
comment the windows section
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

```

* Security Group and Hostname Configuration

Below code creates a security group to allow inbound traffic to ALB. Additionally, it sets the hostname for the instances using a data source called `template_file`. The template file varies based on the operating system of the instances (Linux or Windows). 

_Note: Here also I have added a block of code to uncomment if running from Linux._

```terraform

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
  template = file("${path.module}/user_data.tpl") 
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
```

* Creating AWS EC2 instances and configuring them with Ansible

Below code block creates 3 EC2 instances with Ansible installed, sets the hostname for the instances, and installs Docker and Nginx using Ansible. The provisioner block copies the Ansible script and Jinja2 template to the remote instances and runs the Ansible script using the remote-exec provisioner.

Note: Below code expects _script.yml, user_data.tpl_ and _index.j2_ files in the terraform execution directory, which are included after the terraform code.

```terraform
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
      "$(which ansible-playbook) /tmp/script.yml -i ${self.public_ip} --ssh-common-args='-o StrictHostKeyChecking=no'",
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

```

* script.yml.

This is an Ansible playbook to install Docker, pull the Nginx Docker image, create an index.html template, run a Docker container from the Nginx image, and configure logging to CloudWatch Logs.

```yml
---
- hosts: localhost,127.0.0.1
  become: yes
  tasks:
    - name: Install Docker
      apt:
        name: docker.io
        state: present
        update_cache: yes

    - name: Pull Nginx image
      docker_image:
        name: nginx
        tag: stable
        pull: yes

    - name: Create index.html template
      template:
        src: index.j2
        dest: /tmp/index.html

    - name: Run Nginx container
      docker_container:
        name: nginx
        image: nginx
        ports:
          - "80:80"
        volumes:
          - "/tmp/index.html:/usr/share/nginx/html/index.html"
        log_driver: awslogs
        log_options:
          awslogs-region: us-west-2
          awslogs-group: ContainerLogs
...
``` 

* user_data.tpl

This is a Shell script to set the hostname of a Linux system

```sh
#!/bin/bash
hostnamectl set-hostname ${hostname}
```
* index.j2

This is an HTML template for an Nginx web server that displays a personalized message with the hostname of the server. The message is rendered using the Jinja2 templating engine.

```j2
<html>
<head>
  <title>Nginx Test</title>
</head>
<body>
  <h1>Hello, {{ ansible_hostname }}</h1>
</body>
</html>
```

* IAM and CloudWatch Configuration

Below code defines resources for configuring AWS (IAM) and Amazon CloudWatch for log management. Specifically, it creates an IAM role, a policy to allow EC2 instances to send logs to CloudWatch Logs, attaches the policy to the role, creates an IAM instance profile for the role, and creates a CloudWatch log group with a retention period of 7 days. The resources defined in this code ensure that the Docker and Nginx deployed inside the EC2 instances in the previous code block can send logs to CloudWatch Logs.

```terraform
resource "aws_iam_role" "cwiam" {
  name = "cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "cwpolicy" {
  name        = "cloudwatch-policy"
  description = "A policy to allow EC2 instances to send logs to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "awsiampolatt" {
  role       = aws_iam_role.cwiam.name
  policy_arn = aws_iam_policy.cwpolicy.arn
}


resource "aws_iam_instance_profile" "awsiaminstanceprofile" {
  name = "awsiamcw-profile"
  role = aws_iam_role.cwiam.name
}

resource "aws_cloudwatch_log_group" "awscwlg" {
  name = "ContainerLogs"
  retention_in_days = 7
}
```

* Creating an Application Load Balancer (ALB) and attaching EC2 instances to it.

Below code creates an ALB and attach EC2 instances to it. It creates an ALB listener for port 80 and forwards requests to the target groups based on path pattern. It also creates a target group for each EC2 instance and attaches them to the ALB.

```terraform
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

```

After the deployment is complete, navigate to the Load Balancers section in the AWS console and copy the DNS name to access the deployed application through the load balancer.


<img width="440" alt="image" src="https://user-images.githubusercontent.com/131182048/233602169-4567c47a-d8d7-4474-97bf-8881e1f1e822.png">

![image](https://user-images.githubusercontent.com/131182048/233586531-435417b2-ad93-42f1-9cfa-bbf46b0f73fc.png)
![image](https://user-images.githubusercontent.com/131182048/233586618-36ef20b6-3b72-4f50-a441-d5b20409915b.png)
![image](https://user-images.githubusercontent.com/131182048/233586685-7ed65ec0-dc18-4333-8def-4195b21204b8.png)



## Useful Links and Info

|SlNo                  | Links                                                                                      |
|----------------------|--------------------------------------------------------------------------------------------|
| 1| https://automateinfra.com/2022/01/14/learn-terraform-the-ultimate-terraform-tutorial-part-1/                   |
| 2| https://automateinfra.com/2022/01/16/learn-terraform-the-ultimate-terraform-tutorial-part-2/                   |
| 3| https://developer.hashicorp.com/terraform/language/resources/provisioners/local-exec                           |
| 4| https://developer.hashicorp.com/terraform/language/resources/provisioners/remote-exec                          |
| 5| https://learningtechnix.wordpress.com/2021/04/19/terraform-ansible-automating-configuration-in-infrastructure/ |
| 6| https://progressivecoder.com/how-to-use-terraform-provision-nginx-docker-container/?utm_content=cmp-true       |
| 7| https://jaaaco.medium.com/storing-docker-logs-in-cloudwatch-839db2169a98   





