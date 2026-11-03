############################
# Identity
############################
variable "name" {
  description = "Name prefix for every resource (e.g. acme-support-agent). Lowercase, hyphens only."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,28}$", var.name))
    error_message = "name must be 3-29 chars, lowercase letters, digits and hyphens."
  }
}

############################
# Network
############################
variable "vpc_cidr" {
  description = "CIDR of the customer VPC. Must not overlap the customer's existing networks if it will be peered."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones (2 recommended for HA)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (the internal ALB needs at least two AZs)."
  }
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheaper, lab default). false = one per AZ (production)."
  type        = bool
  default     = true
}

variable "allowed_client_cidrs" {
  description = "CIDRs allowed to call the internal load balancer. Defaults to the VPC itself; add the customer's corporate/VPN ranges here."
  type        = list(string)
  default     = []
}

############################
# Application
############################
variable "image_tag" {
  description = "Container image tag deployed on first apply. Later deploys go through scripts/deploy.sh (Terraform ignores task-definition drift)."
  type        = string
  default     = "bootstrap"
}

variable "llm_model" {
  description = "Model ID the agent calls."
  type        = string
  default     = "claude-sonnet-5-5"
}

variable "llm_provider" {
  description = "anthropic (real model) or mock (offline, for first-deploy smoke tests at zero LLM cost)."
  type        = string
  default     = "anthropic"
  validation {
    condition     = contains(["anthropic", "mock"], var.llm_provider)
    error_message = "llm_provider must be anthropic or mock."
  }
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  description = "Initial number of tasks. Autoscaling manages it afterwards between min_tasks and max_tasks."
  type        = number
  default     = 2
}

variable "min_tasks" {
  type    = number
  default = 2
}

variable "max_tasks" {
  type    = number
  default = 6
}

variable "acm_certificate_arn" {
  description = "Optional ACM certificate (e.g. from the customer's private CA). If set, the ALB listens on HTTPS 443; otherwise HTTP 80 inside the VPC."
  type        = string
  default     = ""
}

############################
# Data protection / ops
############################
variable "log_retention_days" {
  description = "CloudWatch Logs retention. 365 meets common audit requirements."
  type        = number
  default     = 365
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret can be recovered. 0 = immediate delete (lab teardown only)."
  type        = number
  default     = 7
}

variable "lab_mode" {
  description = "true relaxes deletion protection so `terraform destroy` works cleanly. MUST be false for a real customer."
  type        = bool
  default     = false
}

variable "alarm_email" {
  description = "Email subscribed to the alarm SNS topic (confirmation email is sent). Empty = no subscription."
  type        = string
  default     = ""
}

variable "hourly_token_budget" {
  description = "Alarm when input+output tokens in one hour exceed this (cost guardrail)."
  type        = number
  default     = 500000
}

variable "enable_test_client" {
  description = "Create a private, SSM-only EC2 instance that represents a customer user inside the network (used for smoke tests)."
  type        = bool
  default     = true
}

############################
# Human access
############################
variable "human_role_trusted_principals" {
  description = "Principals allowed to assume the admin/operator/auditor roles. Defaults to this account (i.e. its IAM users / SSO roles that are granted sts:AssumeRole)."
  type        = list(string)
  default     = []
}

variable "require_mfa_for_human_roles" {
  type    = bool
  default = true
}

############################
# CI/CD
############################
variable "github_repository" {
  description = "owner/repo allowed to deploy via GitHub Actions OIDC. Empty = no CI role created."
  type        = string
  default     = ""
}

variable "github_deploy_environment" {
  description = "GitHub Actions environment name that may assume the deploy role (environment protection rules add a human approval)."
  type        = string
  default     = "production"
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}
