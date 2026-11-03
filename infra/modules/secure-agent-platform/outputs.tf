output "vpc_id" { value = aws_vpc.this.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "alb_dns_name" {
  description = "Internal DNS name of the agent endpoint (resolvable only inside the VPC / connected networks)."
  value       = aws_lb.this.dns_name
}
output "alb_listener_port" { value = local.lb_port }
output "ecr_repository_url" { value = aws_ecr_repository.agent.repository_url }
output "ecs_cluster_name" { value = aws_ecs_cluster.this.name }
output "ecs_service_name" { value = aws_ecs_service.agent.name }
output "task_definition_family" { value = aws_ecs_task_definition.agent.family }
output "app_log_group" { value = aws_cloudwatch_log_group.app.name }
output "kms_key_arn" { value = aws_kms_key.this.arn }
output "llm_api_key_secret_arn" { value = aws_secretsmanager_secret.llm_api_key.arn }
output "client_api_key_secret_arn" { value = aws_secretsmanager_secret.client_api_key.arn }
output "tickets_table_name" { value = aws_dynamodb_table.tickets.name }
output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.this.dashboard_name }
output "test_client_instance_id" { value = var.enable_test_client ? aws_instance.test_client[0].id : null }

output "role_arns" {
  description = "Roles for the IAM design doc and for mapping to the customer's SSO permission sets."
  value = {
    execution      = aws_iam_role.execution.arn
    task           = aws_iam_role.task.arn
    platform_admin = aws_iam_role.platform_admin.arn
    operator       = aws_iam_role.operator.arn
    auditor        = aws_iam_role.auditor.arn
    github_deploy  = local.create_ci ? aws_iam_role.deploy[0].arn : null
  }
}
