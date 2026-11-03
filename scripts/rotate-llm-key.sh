#!/usr/bin/env bash
# RB-10: rotate the LLM provider key with zero downtime.
#  1. Create a NEW key in the LLM vendor console (keep the old one active).
#  2. Run this script and paste the new key.
#  3. Wait for the verification below to pass, THEN revoke the old key in the vendor console.
source "$(dirname "$0")/lib.sh"
load_env
require LLM_SECRET_ARN SERVICE
read -r -s -p "Paste the NEW LLM API key (input hidden): " LLM_KEY; echo >&2
[[ ${#LLM_KEY} -ge 20 ]] || die "that does not look like an API key"
VERSION="$(printf '%s' "$LLM_KEY" | put_secret_from_stdin "$LLM_SECRET_ARN")"
unset LLM_KEY
log "New version $VERSION is AWSCURRENT. Running tasks switch within 5 minutes (cache TTL)."
log "Waiting 330s, then checking for LLM errors..."
sleep 330
ERRORS="$(aws cloudwatch get-metric-statistics --namespace "AIAgent/$SERVICE" --metric-name LLMErrors \
  --start-time "$(date -u -d '-6 min' +%FT%TZ 2>/dev/null || date -u -v-6M +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 360 --statistics Sum --query 'Datapoints[0].Sum' --output text)"
if [[ "$ERRORS" == "None" || "$ERRORS" == "0.0" ]]; then
  log "No LLM errors since rotation. Run scripts/smoke-test.sh, then revoke the OLD key in the vendor console."
else
  warn "LLMErrors=$ERRORS since rotation. Do NOT revoke the old key. Re-check the new key; to revert:"
  warn "  aws secretsmanager update-secret-version-stage --secret-id $LLM_SECRET_ARN --version-stage AWSCURRENT \\"
  warn "    --move-to-version-id <previous-version-id> --remove-from-version-id $VERSION"
  exit 1
fi
