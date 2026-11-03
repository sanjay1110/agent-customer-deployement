#!/usr/bin/env bash
# RB-21: roll back to a previous task-definition revision.
#   scripts/rollback.sh                    -> previous revision (current - 1)
#   scripts/rollback.sh family:revision    -> that exact revision
source "$(dirname "$0")/lib.sh"
load_env
require CLUSTER SERVICE TASK_FAMILY
CURRENT="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)"
if [[ -n "${1:-}" ]]; then
  TARGET="$1"
else
  REV="${CURRENT##*:}"; (( REV > 1 )) || die "no previous revision"
  TARGET="$TASK_FAMILY:$((REV - 1))"
fi
IMG="$(aws ecs describe-task-definition --task-definition "$TARGET" --query 'taskDefinition.containerDefinitions[0].image' --output text)"
log "Rolling back ${CURRENT##*/} -> $TARGET (image $IMG)"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$TARGET" >/dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
log "Rollback complete. Record it in the incident log and run scripts/smoke-test.sh"
