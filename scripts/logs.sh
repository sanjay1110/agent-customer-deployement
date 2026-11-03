#!/usr/bin/env bash
# Tail the agent's logs.   scripts/logs.sh              (live, last 10 min)
#                          scripts/logs.sh <request-id> (one request end to end)
source "$(dirname "$0")/lib.sh"
load_env
require LOG_GROUP
if [[ -n "${1:-}" ]]; then
  aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$(( ($(date +%s) - 86400) * 1000 ))" \
    --filter-pattern "{ \$.request_id = \"$1\" }" --query 'events[].message' --output text | tr '\t' '\n' | jq -c .
else
  aws logs tail "$LOG_GROUP" --since 10m --follow --format short
fi
