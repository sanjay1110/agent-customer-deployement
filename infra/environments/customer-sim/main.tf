# Simulated customer environment: one dedicated AWS account/VPC that we treat
# exactly like a customer's (private-only networking, customer-owned keys and
# secrets, customer staff roles). All logic lives in the reusable module.
module "platform" {
  source = "../../modules/secure-agent-platform"

  name                 = var.name
  vpc_cidr             = var.vpc_cidr
  az_count             = 2
  single_nat_gateway   = var.lab_mode
  allowed_client_cidrs = var.allowed_client_cidrs

  image_tag    = var.image_tag
  llm_provider = var.llm_provider
  llm_model    = var.llm_model

  min_tasks           = var.min_tasks
  max_tasks           = var.max_tasks
  desired_count       = var.min_tasks
  task_cpu            = var.task_cpu
  task_memory         = var.task_memory
  acm_certificate_arn = var.acm_certificate_arn

  alarm_email         = var.alarm_email
  hourly_token_budget = var.hourly_token_budget
  lab_mode            = var.lab_mode
  enable_test_client  = true

  human_role_trusted_principals = var.human_role_trusted_principals
  github_repository             = var.github_repository
  create_github_oidc_provider   = var.create_github_oidc_provider
}
