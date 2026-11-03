# =============================================================================
# IAM — least privilege. docs/iam-design.md explains every statement.
#
#   Workload identities (no humans):
#     execution role  : lets ECS pull the image and ship logs. Cannot read secrets.
#     task role       : the agent's runtime identity. Reads its 2 secrets, inserts tickets.
#     deploy role     : GitHub Actions (OIDC, no long-lived keys). Pushes images, rolls the service.
#   Human roles (customer staff, MFA required):
#     platform-admin  : owns infrastructure (Terraform). Cannot read secret values.
#     operator        : runs the service day-to-day; rotates secrets without reading them.
#     auditor         : read-only; metadata only, never secret values or ticket contents.
# =============================================================================

locals {
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:*" }
      }
    }]
  })

  human_principals = length(var.human_role_trusted_principals) > 0 ? var.human_role_trusted_principals : ["arn:${local.partition}:iam::${local.account_id}:root"]

  # The Condition key is omitted entirely (not left empty) when MFA is not required.
  human_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [merge(
      {
        Effect    = "Allow"
        Principal = { AWS = local.human_principals }
        Action    = "sts:AssumeRole"
      },
      var.require_mfa_for_human_roles ? { Condition = { Bool = { "aws:MultiFactorAuthPresent" = "true" } } } : {}
    )]
  })

  service_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${local.name}/${local.name}"
}

# ----------------------------------------------------------------- execution role
resource "aws_iam_role" "execution" {
  name                 = "${local.name}-ecs-execution"
  description          = "Used by the ECS agent to pull the image and write container logs"
  assume_role_policy   = local.ecs_trust
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "execution" {
  name = "pull-image-write-logs"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthTokenIsAccountWide"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "PullOnlyThisRepository"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.agent.arn
      },
      {
        Sid      = "WriteOnlyThisLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      },
    ]
  })
}

# ----------------------------------------------------------------- task role
resource "aws_iam_role" "task" {
  name                 = "${local.name}-agent-task"
  description          = "Runtime identity of the AI agent container"
  assume_role_policy   = local.ecs_trust
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "task" {
  name = "agent-runtime"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOnlyItsOwnTwoSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.secret_arns
      },
      {
        Sid      = "DecryptSecretsViaSecretsManagerOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.this.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
        }
      },
      {
        Sid      = "InsertTicketsOnlyNoReadUpdateDelete"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.tickets.arn
      },
      {
        Sid      = "TableEncryptionViaDynamoDbOnly"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = aws_kms_key.this.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "dynamodb.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

# ----------------------------------------------------------------- human: platform admin
resource "aws_iam_role" "platform_admin" {
  name                 = "${local.name}-platform-admin"
  description          = "Customer cloud platform team: applies Terraform for this deployment"
  assume_role_policy   = local.human_trust
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "platform_admin_poweruser" {
  role       = aws_iam_role.platform_admin.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM. Grant IAM only for this deployment's own
# roles/policies (name prefix) plus the GitHub OIDC provider.
resource "aws_iam_role_policy" "platform_admin_iam" {
  #checkov:skip=CKV_AWS_355:Only read-only iam:Get*/List* use "*" (Terraform needs it to plan); all IAM writes are scoped to this deployment's name prefix.
  name = "iam-scoped-to-deployment"
  role = aws_iam_role.platform_admin.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOnlyThisDeploymentsRoles"
        Effect = "Allow"
        Action = ["iam:*Role*", "iam:*InstanceProfile*", "iam:PassRole", "iam:*Policy*", "iam:TagRole", "iam:UntagRole"]
        Resource = [
          "arn:${local.partition}:iam::${local.account_id}:role/${local.name}-*",
          "arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.name}-*",
          "arn:${local.partition}:iam::${local.account_id}:policy/${local.name}-*",
        ]
      },
      {
        Sid      = "GithubOidcProvider"
        Effect   = "Allow"
        Action   = ["iam:*OpenIDConnectProvider*"]
        Resource = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
      },
      {
        Sid      = "ReadIamForPlanning"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "ecs.application-autoscaling.amazonaws.com"] }
        }
      },
    ]
  })
}

# ----------------------------------------------------------------- human: operator
resource "aws_iam_role" "operator" {
  name                 = "${local.name}-operator"
  description          = "Customer operations / on-call: runs the service day to day"
  assume_role_policy   = local.human_trust
  max_session_duration = 14400
}

resource "aws_iam_role_policy" "operator" {
  name = "operate-agent"
  role = aws_iam_role.operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeEverythingNeededToTriage"
        Effect   = "Allow"
        Action   = ["ecs:Describe*", "ecs:List*", "elasticloadbalancing:Describe*", "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*", "logs:Describe*", "logs:GetQueryResults", "logs:StopQuery", "ec2:DescribeInstances", "ecr:DescribeImages", "ecr:DescribeImageScanFindings", "application-autoscaling:Describe*", "dynamodb:DescribeTable"]
        Resource = "*"
      },
      {
        Sid      = "RestartRollbackScaleThisServiceOnly"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.service_arn
      },
      {
        Sid      = "StopTasksInThisClusterOnly"
        Effect   = "Allow"
        Action   = ["ecs:StopTask"]
        Resource = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${local.name}/*"
      },
      {
        Sid      = "ReadThisDeploymentsLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:StartLiveTail"]
        Resource = [aws_cloudwatch_log_group.app.arn, "${aws_cloudwatch_log_group.app.arn}:*", aws_cloudwatch_log_group.flow_logs.arn, "${aws_cloudwatch_log_group.flow_logs.arn}:*"]
      },
      {
        Sid      = "MuteAndDrillAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DisableAlarmActions", "cloudwatch:EnableAlarmActions", "cloudwatch:SetAlarmState"]
        Resource = "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name}-*"
      },
      {
        Sid      = "RotateSecretsWithoutReadingThem"
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage", "secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds"]
        Resource = local.secret_arns
      },
      {
        Sid      = "EncryptNewSecretVersions"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt"]
        Resource = aws_kms_key.this.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
        }
      },
      {
        Sid    = "PortForwardThroughTestClientOnly"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = concat(
          [for i in aws_instance.test_client : i.arn],
          ["arn:${local.partition}:ssm:${local.region}::document/AWS-StartPortForwardingSessionToRemoteHost"]
        )
      },
      {
        Sid      = "ManageOwnSsmSessions"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
        Resource = "arn:${local.partition}:ssm:*:*:session/$${aws:userid}-*"
      },
    ]
  })
}

# ----------------------------------------------------------------- human: auditor
resource "aws_iam_role" "auditor" {
  name                 = "${local.name}-auditor"
  description          = "Security / compliance: read-only metadata and logs; no secret values, no ticket data"
  assume_role_policy   = local.human_trust
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "auditor_security_audit" {
  role       = aws_iam_role.auditor.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy" "auditor_logs" {
  name = "read-deployment-logs"
  role = aws_iam_role.auditor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDeploymentLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
        Resource = [aws_cloudwatch_log_group.app.arn, "${aws_cloudwatch_log_group.app.arn}:*", aws_cloudwatch_log_group.flow_logs.arn, "${aws_cloudwatch_log_group.flow_logs.arn}:*"]
      },
      {
        Sid      = "ExplicitlyNoSecretValuesOrCustomerData"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchGetItem"]
        Resource = "*"
      },
    ]
  })
}

# ----------------------------------------------------------------- CI/CD deploy role (GitHub OIDC)
locals {
  create_ci = var.github_repository != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.create_ci && var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = local.create_ci && !var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "deploy" {
  count                = local.create_ci ? 1 : 0
  name                 = "${local.name}-github-deploy"
  description          = "Assumed by GitHub Actions via OIDC to release new images. No long-lived keys."
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Only jobs that run in the protected GitHub environment of this repo.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.github_deploy_environment}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  count = local.create_ci ? 1 : 0
  name  = "release-agent"
  role  = aws_iam_role.deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "EcrLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid      = "PushToThisRepositoryOnly"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
        Resource = aws_ecr_repository.agent.arn
      },
      {
        Sid      = "TaskDefinitionsCannotBeResourceScoped"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid      = "RollThisServiceOnly"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = local.service_arn
      },
      {
        Sid      = "PassOnlyTheAgentRolesToEcs"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}
