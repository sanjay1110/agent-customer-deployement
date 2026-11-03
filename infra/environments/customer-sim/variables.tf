variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "acme-support-agent"
}

variable "owner_tag" {
  description = "Team that owns the deployment after hand-over (cost allocation / escalation)."
  type        = string
  default     = "acme-platform-ops"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "allowed_client_cidrs" {
  type    = list(string)
  default = []
}

variable "image_tag" {
  type    = string
  default = "bootstrap"
}

variable "llm_provider" {
  type    = string
  default = "anthropic"
}

variable "llm_model" {
  type    = string
  default = "claude-sonnet-5-5"
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "hourly_token_budget" {
  type    = number
  default = 500000
}

variable "lab_mode" {
  description = "true = cheaper single NAT + easy teardown. Set false for a real customer."
  type        = bool
  default     = true
}

variable "human_role_trusted_principals" {
  type    = list(string)
  default = []
}

variable "github_repository" {
  type    = string
  default = ""
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

variable "min_tasks" {
  type    = number
  default = 2
}

variable "max_tasks" {
  type    = number
  default = 6
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "acm_certificate_arn" {
  description = "Certificate from the customer's private CA; enables HTTPS 443 on the internal ALB (closes residual risk R-2)."
  type        = string
  default     = ""
}
