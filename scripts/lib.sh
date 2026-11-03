#!/usr/bin/env bash
# Shared helpers. Every script sources this file.
# Settings come from environment variables if set (CI), otherwise from
# `terraform output` of infra/environments/customer-sim (operator laptop).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/infra/environments/customer-sim}"
TF="${TF:-terraform}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required tool: $c"; done; }

_tf_out() { (cd "$TF_DIR" && "$TF" output -raw "$1" 2>/dev/null) || true; }

load_env() {
  need aws jq
  : "${AWS_REGION:=$(_tf_out region)}"
  : "${CLUSTER:=$(_tf_out ecs_cluster_name)}"
  : "${SERVICE:=$(_tf_out ecs_service_name)}"
  : "${TASK_FAMILY:=$(_tf_out task_definition_family)}"
  : "${ECR_REPO_URL:=$(_tf_out ecr_repository_url)}"
  : "${LLM_SECRET_ARN:=$(_tf_out llm_api_key_secret_arn)}"
  : "${CLIENT_SECRET_ARN:=$(_tf_out client_api_key_secret_arn)}"
  : "${ALB_DNS:=$(_tf_out alb_dns_name)}"
  : "${ALB_PORT:=$(_tf_out alb_listener_port)}"
  : "${TEST_CLIENT_ID:=$(_tf_out test_client_instance_id)}"
  : "${LOG_GROUP:=$(_tf_out app_log_group)}"
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" CLUSTER SERVICE TASK_FAMILY ECR_REPO_URL \
         LLM_SECRET_ARN CLIENT_SECRET_ARN ALB_DNS ALB_PORT TEST_CLIENT_ID LOG_GROUP
  [[ -n "$AWS_REGION" ]] || die "could not load settings (run 'terraform apply' first or export the variables)"
}

require() {  # require VAR1 VAR2 ... to be non-empty
  for v in "$@"; do [[ -n "${!v:-}" && "${!v}" != "null" ]] || die "$v is not set (has 'terraform apply' completed?)"; done
}

# Write a secret value via a 0600 temp file so it never appears in `ps` output or shell history.
put_secret_from_stdin() {
  local secret_arn="$1" tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  trap 'rm -f "$tmp"' RETURN
  cat > "$tmp"
  aws secretsmanager put-secret-value --secret-id "$secret_arn" --secret-string "file://$tmp" \
    --query VersionId --output text
}

generate_client_key() {
  # 48 URL-safe characters (~285 bits of entropy)
  python3 -c 'import secrets; print(secrets.token_urlsafe(36))'
}
