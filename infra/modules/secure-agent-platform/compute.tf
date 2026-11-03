# -----------------------------------------------------------------------------
# Internal ALB -> ECS Fargate service
# -----------------------------------------------------------------------------

locals {
  use_https = var.acm_certificate_arn != ""
  lb_port   = local.use_https ? 443 : 80
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internal ALB: accepts customer client CIDRs only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_clients" {
  for_each          = toset(local.client_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "Customer clients"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.lb_port
  to_port           = local.lb_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to agent tasks only"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Agent tasks: inbound from ALB only; outbound HTTPS only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "From internal ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

# HTTPS only. Covers VPC endpoints, the S3/DynamoDB gateway endpoints and the
# LLM API via NAT. Security groups cannot filter by domain name; see
# docs/security-summary.md "Residual risks" for the egress-firewall upgrade.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS egress (AWS endpoints + LLM provider via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:Deletion protection is on whenever lab_mode=false (asserted in tests/security_controls.tftest.hcl).
  #checkov:skip=CKV2_AWS_20:No internet listener exists. HTTPS is used when acm_certificate_arn is set; see docs/security-summary.md R-2.
  name                       = substr("${local.name}-alb", 0, 32)
  internal                   = true # no internet-facing listener exists anywhere in this design
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.private[*].id
  drop_invalid_header_fields = true
  enable_deletion_protection = !var.lab_mode
  idle_timeout               = 120 # agent calls can take tens of seconds

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ALB access logs (every request: client IP, path, status, latency).
# ALB log delivery only supports SSE-S3, not a customer KMS key.
data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_18:This IS the access-log bucket; logging it to itself would recurse.
  #checkov:skip=CKV_AWS_144:Single-region deployment; cross-region replication is a customer DR decision (docs/runbook.md DR section).
  #checkov:skip=CKV_AWS_145:ALB log delivery supports SSE-S3 only.
  #checkov:skip=CKV2_AWS_62:No consumer for object events; logs are queried with Athena when needed.
  bucket        = "${local.name}-alb-logs-${local.account_id}"
  force_destroy = var.lab_mode
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ElbLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.this.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${local.account_id}/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

resource "aws_lb_target_group" "agent" {
  #checkov:skip=CKV_AWS_378:ALB-to-task hop is inside private subnets and locked by security groups to the ALB only; TLS ends at the ALB.
  name                 = substr("${local.name}-tg", 0, 32)
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:Internal-only listener used when no certificate is supplied (lab). Set acm_certificate_arn for HTTPS; residual risk R-2.
  #checkov:skip=CKV_AWS_103:Same as CKV_AWS_2.
  count             = local.use_https ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }
}

resource "aws_lb_listener" "https" {
  count             = local.use_https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }
}

# ----------------------------------------------------------------- ECS
resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_app
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_ecs_task_definition" "agent" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "tmp" # writable scratch space; the root filesystem is read-only
  }

  container_definitions = jsonencode([{
    name                   = "agent"
    image                  = "${aws_ecr_repository.agent.repository_url}:${var.image_tag}"
    essential              = true
    user                   = "10001"
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = local.container_port, protocol = "tcp" }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters = {
      initProcessEnabled = true
      capabilities       = { drop = ["ALL"] }
    }
    # Non-secret configuration only. Secret VALUES are fetched at runtime by the
    # app from Secrets Manager using the task role; only their IDs appear here.
    environment = [
      { name = "APP_ENV", value = "aws" },
      { name = "SERVICE_NAME", value = local.name },
      { name = "LLM_PROVIDER", value = var.llm_provider },
      { name = "LLM_MODEL", value = var.llm_model },
      { name = "LLM_API_KEY_SECRET_ID", value = aws_secretsmanager_secret.llm_api_key.arn },
      { name = "CLIENT_API_KEY_SECRET_ID", value = aws_secretsmanager_secret.client_api_key.arn },
      { name = "TICKETS_BACKEND", value = "dynamodb" },
      { name = "TICKETS_TABLE_NAME", value = aws_dynamodb_table.tickets.name },
      { name = "LOG_LEVEL", value = "INFO" },
      { name = "LOG_CONVERSATION_CONTENT", value = "false" },
    ]
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status==200 else 1)"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "agent"
        mode                  = "non-blocking"
        max-buffer-size       = "4m"
      }
    }
  }])
}

resource "aws_ecs_service" "agent" {
  name                               = local.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.agent.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 30
  enable_execute_command             = false # no shell into production containers
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a deploy whose tasks fail health checks reverts automatically
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.agent.arn
    container_name   = "agent"
    container_port   = local.container_port
  }

  # Application releases are done by scripts/deploy.sh (new task-definition
  # revision + update-service). Autoscaling owns desired_count.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
}

resource "aws_appautoscaling_target" "agent" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.agent.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.agent.service_namespace
  resource_id        = aws_appautoscaling_target.agent.resource_id
  scalable_dimension = aws_appautoscaling_target.agent.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ----------------------------------------------------------------- test client
# A private EC2 instance with NO SSH key, NO public IP and NO inbound rules.
# It represents a customer user inside the network. Operators reach it (and
# through it, the internal ALB) only via SSM Session Manager port forwarding.
data "aws_ssm_parameter" "al2023" {
  count = var.enable_test_client ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "test_client" {
  count       = var.enable_test_client ? 1 : 0
  name        = "${local.name}-test-client"
  description = "SSM-managed test client: no inbound; outbound to VPC only"
  vpc_id      = aws_vpc.this.id
  egress {
    description = "HTTP/HTTPS to ALB and VPC endpoints"
    from_port   = 80
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${local.name}-test-client" }
}

resource "aws_iam_role" "test_client" {
  count = var.enable_test_client ? 1 : 0
  name  = "${local.name}-test-client"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "test_client_ssm" {
  count      = var.enable_test_client ? 1 : 0
  role       = aws_iam_role.test_client[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "test_client" {
  count = var.enable_test_client ? 1 : 0
  name  = "${local.name}-test-client"
  role  = aws_iam_role.test_client[0].name
}

resource "aws_instance" "test_client" {
  #checkov:skip=CKV_AWS_126:Test client only; basic monitoring is sufficient.
  count                       = var.enable_test_client ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023[0].value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.test_client[0].id]
  iam_instance_profile        = aws_iam_instance_profile.test_client[0].name
  associate_public_ip_address = false
  ebs_optimized               = true
  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }
  root_block_device {
    encrypted   = true
    volume_size = 8
  }
  tags       = { Name = "${local.name}-test-client" }
  depends_on = [aws_vpc_endpoint.interface]
  lifecycle {
    ignore_changes = [ami]
  }
}
