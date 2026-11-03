#!/usr/bin/env bash
# RB-20: release a new version of the agent.
#   scripts/deploy.sh [image-tag]        default tag = current git short SHA
#   SKIP_BUILD=1 scripts/deploy.sh <tag>  re-deploy an image already in ECR
#   PUSH_ONLY=1 scripts/deploy.sh <tag>   build + push + scan only (first install, before the service exists)
# Steps: build -> push (immutable tag) -> wait for scan -> new task-def revision -> rolling update -> wait stable.
# The ECS deployment circuit breaker rolls back automatically if new tasks fail health checks.
source "$(dirname "$0")/lib.sh"
load_env
require ECR_REPO_URL
need docker

TAG="${1:-$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)}"
IMAGE="$ECR_REPO_URL:$TAG"
REGISTRY="${ECR_REPO_URL%%/*}"
REPO_NAME="${ECR_REPO_URL#*/}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "Building $IMAGE"
  docker build --platform linux/amd64 -t "$IMAGE" "$REPO_ROOT/agent"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
  log "Pushing (tags are immutable: an existing tag cannot be overwritten)"
  docker push "$IMAGE"
fi

log "Waiting for the ECR vulnerability scan"
aws ecr wait image-scan-complete --repository-name "$REPO_NAME" --image-id imageTag="$TAG" || warn "scan wait timed out"
CRIT="$(aws ecr describe-image-scan-findings --repository-name "$REPO_NAME" --image-id imageTag="$TAG" \
  --query 'imageScanFindings.findingSeverityCounts.CRITICAL' --output text 2>/dev/null || echo None)"
if [[ "$CRIT" != "None" && "$CRIT" != "0" ]]; then
  [[ "${ALLOW_CRITICAL:-0}" == "1" ]] || die "image has $CRIT CRITICAL vulnerabilities (set ALLOW_CRITICAL=1 to override with sign-off)"
fi

if [[ "${PUSH_ONLY:-0}" == "1" ]]; then
  log "Pushed $IMAGE. Now run: terraform apply -var image_tag=$TAG"
  exit 0
fi
require CLUSTER SERVICE TASK_FAMILY

CURRENT_TD="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)"
log "Current task definition: $CURRENT_TD"

# Start from the LATEST revision of the family so Terraform-made config changes are kept.
NEW_TD_JSON="$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY" --query taskDefinition \
  | jq --arg img "$IMAGE" '.containerDefinitions[0].image = $img
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)')"
NEW_TD="$(aws ecs register-task-definition --cli-input-json "$NEW_TD_JSON" --query 'taskDefinition.taskDefinitionArn' --output text)"
log "Registered $NEW_TD"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW_TD" >/dev/null
log "Rolling update started; waiting for the service to become stable (up to ~10 min)"
if aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"; then
  RUNNING_TD="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)"
  if [[ "$RUNNING_TD" != "$NEW_TD" ]]; then
    die "circuit breaker rolled back to $RUNNING_TD. Check: scripts/status.sh and the 'recent-errors' Logs Insights query"
  fi
  log "Deployed $TAG. Rollback command if needed: scripts/rollback.sh ${CURRENT_TD##*/}"
else
  die "service did not stabilise. Check scripts/status.sh; roll back with: scripts/rollback.sh ${CURRENT_TD##*/}"
fi
