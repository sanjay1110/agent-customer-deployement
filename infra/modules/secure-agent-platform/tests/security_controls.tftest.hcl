# Plan-time security tests. They run with a MOCKED AWS provider, so they need
# no AWS account and cost nothing:   cd infra/modules/secure-agent-platform && terraform test
# Each assertion is a control from docs/security-summary.md that must never regress.

mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-alb-logs" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::127311923021:root" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111122223333:mock-topic" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock-role" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:mock-AbCdEf" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:111122223333:table/mock" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:us-east-1:111122223333:repository/mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/mock/0123456789abcdef" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/mock/0123456789abcdef" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:cluster/mock" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:task-definition/mock:1" }
  }
  mock_resource "aws_instance" {
    defaults = { arn = "arn:aws:ec2:us-east-1:111122223333:instance/i-0123456789abcdef0" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::111122223333:instance-profile/mock" }
  }
  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = { arn = "arn:aws:cloudwatch:us-east-1:111122223333:alarm:mock" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }
  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  override_data {
    target = data.aws_ssm_parameter.al2023
    values = { value = "ami-0123456789abcdef0" }
  }
  override_resource {
    target = aws_iam_role.task
    values = { arn = "arn:aws:iam::111122223333:role/acme-test-agent-task" }
  }
  override_resource {
    target = aws_kms_key.this
    values = { arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
  }
}

variables {
  name              = "acme-test"
  github_repository = "example/ai-agent-customer-deployment"
  alarm_email       = "ops@example.com"
}

run "network_is_private" {
  command = plan

  assert {
    condition     = aws_lb.this.internal == true
    error_message = "The load balancer must be internal (no internet-facing entry point)."
  }
  assert {
    condition     = aws_ecs_service.agent.network_configuration[0].assign_public_ip == false
    error_message = "Agent tasks must not get public IPs."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Even public (NAT) subnets must not auto-assign public IPs."
  }
  assert {
    condition     = var.enable_test_client == false || aws_instance.test_client[0].associate_public_ip_address == false
    error_message = "Test client must be private."
  }
  assert {
    condition     = length(aws_flow_log.this.traffic_type) > 0 && aws_flow_log.this.traffic_type == "ALL"
    error_message = "VPC flow logs must capture ALL traffic."
  }
  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "ssm", "ssmmessages", "ec2messages"])
    error_message = "Unexpected set of interface VPC endpoints."
  }
}

run "alb_access_logs_enabled" {
  command = plan

  assert {
    condition     = aws_lb.this.access_logs[0].enabled == true
    error_message = "ALB access logs must be enabled."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.alb_logs.restrict_public_buckets == true
    error_message = "ALB log bucket must block public access."
  }
}

run "container_is_hardened" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecs_task_definition.agent.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "Root filesystem must be read-only."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.agent.container_definitions)[0].user == "10001"
    error_message = "Container must run as non-root UID 10001."
  }
  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.agent.container_definitions)[0].linuxParameters.capabilities.drop, "ALL")
    error_message = "All Linux capabilities must be dropped."
  }
  assert {
    condition     = aws_ecs_service.agent.enable_execute_command == false
    error_message = "ECS Exec (shell into containers) must be disabled."
  }
  assert {
    condition     = aws_ecs_service.agent.deployment_circuit_breaker[0].rollback == true
    error_message = "Failed deployments must roll back automatically."
  }
}

run "no_secret_values_in_config" {
  command = plan

  assert {
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.agent.container_definitions)[0].environment :
      !can(regex("(?i)(sk-ant|password|secret_value)", e.value))
    ])
    error_message = "Environment variables must hold secret IDs, never secret values."
  }
  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.agent.container_definitions)[0].secrets)
    error_message = "Secrets must be fetched at runtime by the task role, not injected by ECS."
  }
  assert {
    condition     = aws_secretsmanager_secret.llm_api_key.kms_key_id != null && aws_secretsmanager_secret.client_api_key.kms_key_id != null
    error_message = "Secrets must be encrypted with the customer-managed KMS key."
  }
  assert {
    condition     = strcontains(aws_secretsmanager_secret_policy.only_task_role_reads["llm"].policy, "DenyValueReadExceptAgentTaskRole")
    error_message = "Secret resource policy must deny value reads to everyone except the task role."
  }
}

run "encryption_at_rest" {
  command = plan

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true
    error_message = "KMS key rotation must be enabled."
  }
  assert {
    condition     = aws_dynamodb_table.tickets.server_side_encryption[0].enabled == true
    error_message = "Tickets table must use KMS encryption."
  }
  assert {
    condition     = aws_dynamodb_table.tickets.point_in_time_recovery[0].enabled == true
    error_message = "Tickets table must have point-in-time recovery."
  }
  assert {
    condition     = aws_ecr_repository.agent.image_tag_mutability == "IMMUTABLE"
    error_message = "Image tags must be immutable (reliable rollback, no tag hijack)."
  }
  assert {
    condition     = aws_ecr_repository.agent.image_scanning_configuration[0].scan_on_push == true
    error_message = "Images must be scanned on push."
  }
}

run "least_privilege_iam" {
  command = plan

  assert {
    condition     = !strcontains(aws_iam_role_policy.task.policy, "\"*\"") && !strcontains(aws_iam_role_policy.task.policy, "dynamodb:*")
    error_message = "Task role must not use wildcard actions or resources."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.task.policy, "GetItem") && !strcontains(aws_iam_role_policy.task.policy, "DeleteItem") && !strcontains(aws_iam_role_policy.task.policy, "Scan")
    error_message = "Task role may only INSERT tickets."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "secretsmanager")
    error_message = "Execution role must not be able to read secrets."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.operator.policy, "GetSecretValue")
    error_message = "Operators rotate secrets but must never read them."
  }
  assert {
    condition     = strcontains(aws_iam_role.deploy[0].assume_role_policy, "repo:example/ai-agent-customer-deployment:environment:production")
    error_message = "CI deploy role must be pinned to one repo and one protected environment."
  }
  assert {
    condition     = strcontains(aws_iam_role.operator.assume_role_policy, "aws:MultiFactorAuthPresent")
    error_message = "Human roles must require MFA."
  }
}

run "alarms_route_to_oncall" {
  command = plan

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : length(a.alarm_actions) > 0])
    error_message = "Every alarm must notify the on-call SNS topic."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) + 1 == 12
    error_message = "Expected the 12 alarms listed in docs/monitoring.md."
  }
}

run "trust_policy_without_mfa_has_no_empty_condition" {
  command = plan
  variables {
    require_mfa_for_human_roles = false
  }
  assert {
    condition     = !strcontains(aws_iam_role.operator.assume_role_policy, "Condition")
    error_message = "With MFA disabled the trust policy must omit Condition entirely (IAM rejects an empty block)."
  }
}

run "production_mode_keeps_protection" {
  command = plan
  variables {
    lab_mode = false
  }
  assert {
    condition     = aws_lb.this.enable_deletion_protection == true && aws_dynamodb_table.tickets.deletion_protection_enabled == true
    error_message = "With lab_mode=false, ALB and table deletion protection must be on."
  }
  assert {
    condition     = aws_secretsmanager_secret.llm_api_key.recovery_window_in_days == 7
    error_message = "With lab_mode=false, deleted secrets must be recoverable."
  }
}
