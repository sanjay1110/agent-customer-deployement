# -----------------------------------------------------------------------------
# Customer VPC
#
#   public subnets  (/24)  : NAT gateway ONLY. Nothing else is ever placed here,
#                            and no resource gets a public IP.
#   private subnets (/20)  : ALB (internal), ECS tasks, VPC endpoints, test client.
#
# Egress paths from the agent tasks:
#   AWS APIs (ECR, Logs, Secrets Manager, S3, DynamoDB) -> VPC endpoints (never leave AWS network)
#   LLM provider API (api.anthropic.com:443)             -> NAT gateway -> internet
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:We take the first az_count zones by name; adding AZs to the region does not change that slice.
  state = "available"
}

locals {
  azs           = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  client_cidrs  = length(var.allowed_client_cidrs) > 0 ? var.allowed_client_cidrs : [var.vpc_cidr]
  nat_count     = var.single_nat_gateway ? 1 : var.az_count
  interface_eps = toset(concat(["ecr.api", "ecr.dkr", "logs", "secretsmanager"], var.enable_test_client ? ["ssm", "ssmmessages", "ec2messages"] : []))
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for private DNS on interface endpoints
  tags                 = { Name = "${local.name}-vpc" }
}

# Remove all rules from the default security group so nothing can use it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-default-locked" }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.40.0.0/24, 10.40.1.0/24
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public-nat-only" }
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 1) # 10.40.16.0/20, 10.40.32.0/20
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${local.azs[count.index]}", Tier = "private" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }
  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ----------------------------------------------------------------- flow logs
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${local.name}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name}-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn    = aws_iam_role.flow_logs.arn
}

# ----------------------------------------------------------------- VPC endpoints
resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id
  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${local.name}-vpc-endpoints" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_eps
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.value}" }
}

# S3 gateway endpoint: ECR stores image layers in S3. The endpoint policy only
# allows the ECR layer bucket and Amazon Linux package repos, so the VPC cannot
# be used to exfiltrate data to an arbitrary S3 bucket.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EcrLayersAndOsReposOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject"]
      Resource = [
        "arn:${local.partition}:s3:::prod-${local.region}-starport-layer-bucket/*",
        "arn:${local.partition}:s3:::al2023-repos-${local.region}-*/*",
      ]
    }]
  })
  tags = { Name = "${local.name}-s3" }
}

# DynamoDB gateway endpoint restricted to the tickets table.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TicketsTableOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["dynamodb:PutItem", "dynamodb:DescribeTable"]
      Resource  = aws_dynamodb_table.tickets.arn
    }]
  })
  tags = { Name = "${local.name}-dynamodb" }
}
