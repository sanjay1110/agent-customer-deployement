#!/usr/bin/env bash
# First-time secret population (run once after `terraform apply`).
#   - LLM API key: typed at a hidden prompt (never echoed, never in history or argv).
#   - Client API key: generated here, stored in Secrets Manager, shown ONCE so you can
#     hand it to the consuming team through the customer's approved secure channel.
# Requires the operator or platform-admin role. Nobody can read the values back later.
source "$(dirname "$0")/lib.sh"
load_env
require LLM_SECRET_ARN CLIENT_SECRET_ARN

if [[ "${1:-}" != "--client-only" ]]; then
  read -r -s -p "Paste the LLM provider API key (input hidden): " LLM_KEY; echo >&2
  [[ ${#LLM_KEY} -ge 20 ]] || die "that does not look like an API key"
  printf '%s' "$LLM_KEY" | put_secret_from_stdin "$LLM_SECRET_ARN" >/dev/null
  unset LLM_KEY
  log "LLM API key stored (AWSCURRENT)."
fi

CLIENT_KEY="$(generate_client_key)"
printf '%s' "$CLIENT_KEY" | put_secret_from_stdin "$CLIENT_SECRET_ARN" >/dev/null
log "Client API key stored (AWSCURRENT)."
cat >&2 <<MSG

================================================================================
 CLIENT API KEY (shown once; deliver via the customer's secure channel):

   $CLIENT_KEY

 Callers send it as the header:  X-API-Key: <key>
================================================================================
MSG
unset CLIENT_KEY
log "Tasks pick up new values within 5 minutes (secret cache TTL). Verify with scripts/smoke-test.sh"
