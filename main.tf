terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
  default_tags {
    tags = { Project = "it4200-class-api", ManagedBy = "Terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}
variable "profile" {
  type    = string
  default = "class-aws"
}
variable "image" {
  type    = string
  default = "bubbaj/it4200-fall-2026@sha256:265c5e4b23650f84028462c26fa031b9f9db7b5fc5fd97e70af903a7f94cd82b"
}

locals {
  name = "zander-it4200-api"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "api" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}
resource "aws_internet_gateway" "api" {
  vpc_id = aws_vpc.api.id
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.api.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.api.cidr_block, 8, count.index)
  map_public_ip_on_launch = false
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.api.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.api.id
  }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Public HTTP entry point"
  vpc_id      = aws_vpc.api.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.api.cidr_block]
  }
}
resource "aws_security_group" "task" {
  name_prefix = "${local.name}-task-"
  description = "API accepts traffic only from the load balancer"
  vpc_id      = aws_vpc.api.id
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "api" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  depends_on         = [aws_internet_gateway.api]
}
resource "aws_lb_target_group" "api" {
  name        = local.name
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.api.id
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}
resource "aws_iam_role" "execution" {
  name = "${local.name}-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "logs" {
  name = "write-container-logs"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.api.arn}:*"
    }]
  })
}
resource "aws_ecs_cluster" "api" {
  name = local.name
}
resource "aws_ecs_task_definition" "api" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "class-api"
    image        = var.image
    essential    = true
    command      = ["python", "-m", "flask", "--app", "app", "run", "--host=0.0.0.0", "--port=8000"]
    portMappings = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]
    environment  = [{ name = "FLASK_DEBUG", value = "0" }, { name = "PYTHONUNBUFFERED", value = "1" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}
resource "aws_ecs_service" "api" {
  name                              = local.name
  cluster                           = aws_ecs_cluster.api.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  health_check_grace_period_seconds = 60
  wait_for_steady_state             = true
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "class-api"
    container_port   = 8000
  }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.logs, aws_route_table_association.public]
}

output "cluster_name" { value = aws_ecs_cluster.api.name }
output "service_name" { value = aws_ecs_service.api.name }
output "target_group_arn" { value = aws_lb_target_group.api.arn }
output "api_url" { value = "http://${aws_lb.api.dns_name}" }
output "dns_name" { value = aws_lb.api.dns_name }
