# -----------------------------------------------------------------------------
# KMS, Secrets Manager, DynamoDB, ECR
# -----------------------------------------------------------------------------

# One customer-managed key for this deployment's data: secrets, tickets table,
# log groups, SNS topic and container images. Annual automatic rotation is on.
resource "aws_kms_key" "this" {
  description             = "${local.name} data key (secrets, tickets, logs, alarms, images)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministersKeyViaIAM"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogsEncryptsLogGroups"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*" }
        }
      },
      {
        Sid       = "CloudWatchAlarmsPublishToEncryptedSns"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}

# ----------------------------------------------------------------- secrets
# Terraform creates the secret CONTAINERS only. Values are written out-of-band
# with scripts/set-secrets.sh so that no secret ever lands in Terraform state,
# plan output or CI logs.
resource "aws_secretsmanager_secret" "llm_api_key" {
  #checkov:skip=CKV2_AWS_57:Rotated by runbook procedure RB-10/RB-11 (scripts/rotate-*.sh); the LLM vendor key can only be issued in the vendor console, so a rotation Lambda cannot mint it.
  name                    = "${local.name}/llm-api-key"
  description             = "LLM provider API key (plain string). Rotate: scripts/rotate-llm-key.sh"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = var.lab_mode ? 0 : var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "client_api_key" {
  #checkov:skip=CKV2_AWS_57:Rotated by runbook procedure RB-10/RB-11 (scripts/rotate-*.sh); the LLM vendor key can only be issued in the vendor console, so a rotation Lambda cannot mint it.
  name                    = "${local.name}/client-api-key"
  description             = "Key callers send in X-API-Key. AWSCURRENT and AWSPREVIOUS are both accepted (rotation overlap). Rotate: scripts/rotate-client-key.sh"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = var.lab_mode ? 0 : var.secret_recovery_window_days
}

locals {
  secret_arns = [aws_secretsmanager_secret.llm_api_key.arn, aws_secretsmanager_secret.client_api_key.arn]
}

# Resource policy = second lock independent of IAM: ONLY the agent task role
# may read secret values. Admins and operators can write/rotate but never read.
resource "aws_secretsmanager_secret_policy" "only_task_role_reads" {
  for_each = {
    llm    = aws_secretsmanager_secret.llm_api_key.arn
    client = aws_secretsmanager_secret.client_api_key.arn
  }
  secret_arn = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyValueReadExceptAgentTaskRole"
      Effect    = "Deny"
      Principal = "*"
      Action    = "secretsmanager:GetSecretValue"
      Resource  = "*"
      Condition = {
        ArnNotEquals = { "aws:PrincipalArn" = aws_iam_role.task.arn }
      }
    }]
  })
}

# ----------------------------------------------------------------- tickets table
resource "aws_dynamodb_table" "tickets" {
  name                        = "${local.name}-tickets"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "ticket_id"
  deletion_protection_enabled = !var.lab_mode

  attribute {
    name = "ticket_id"
    type = "S"
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.this.arn
  }
  point_in_time_recovery {
    enabled = true
  }
}

# ----------------------------------------------------------------- image registry
resource "aws_ecr_repository" "agent" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # a tag always means the same bytes -> reliable rollback
  force_delete         = var.lab_mode
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.this.arn
  }
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images (rollback window)"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}
