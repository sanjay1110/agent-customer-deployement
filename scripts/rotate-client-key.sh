#!/usr/bin/env bash
# RB-11: rotate the client API key with an overlap window.
#   scripts/rotate-client-key.sh start    -> new key becomes AWSCURRENT, old key stays valid as AWSPREVIOUS
#   (distribute the new key; consumers switch)
#   scripts/rotate-client-key.sh finish   -> removes AWSPREVIOUS; old key stops working within 5 minutes
# The operator never reads an existing key; the old value is never shown.
source "$(dirname "$0")/lib.sh"
load_env
require CLIENT_SECRET_ARN

case "${1:-}" in
  start)
    NEW_KEY="$(generate_client_key)"
    printf '%s' "$NEW_KEY" | put_secret_from_stdin "$CLIENT_SECRET_ARN" >/dev/null
    log "New key is AWSCURRENT; previous key remains valid as AWSPREVIOUS."
    printf '\nNEW CLIENT API KEY (shown once): %s\n\n' "$NEW_KEY" >&2
    unset NEW_KEY
    log "When every consumer has switched (AuthFailures metric stays flat), run: $0 finish"
    ;;
  finish)
    PREV="$(aws secretsmanager list-secret-version-ids --secret-id "$CLIENT_SECRET_ARN" \
      --query "Versions[?contains(VersionStages, 'AWSPREVIOUS')].VersionId | [0]" --output text)"
    [[ "$PREV" != "None" && -n "$PREV" ]] || die "no AWSPREVIOUS version; nothing to revoke"
    aws secretsmanager update-secret-version-stage --secret-id "$CLIENT_SECRET_ARN" \
      --version-stage AWSPREVIOUS --remove-from-version-id "$PREV"
    log "Old key ($PREV) revoked. Tasks stop accepting it within 5 minutes."
    ;;
  *) die "usage: $0 start|finish" ;;
esac
