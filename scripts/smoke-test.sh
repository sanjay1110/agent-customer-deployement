#!/usr/bin/env bash
# RB-30: end-to-end check FROM INSIDE the customer network.
# The ALB is internal, so we tunnel through the private test client with SSM
# Session Manager (no SSH, no public IP, every session audited in CloudTrail).
# Needs: AWS CLI + session-manager-plugin. Prompts for the client API key (hidden).
source "$(dirname "$0")/lib.sh"
load_env
require ALB_DNS ALB_PORT TEST_CLIENT_ID
need curl session-manager-plugin

LOCAL_PORT="${LOCAL_PORT:-18080}"
if [[ -z "${CLIENT_API_KEY:-}" ]]; then
  read -r -s -p "Client API key (input hidden): " CLIENT_API_KEY; echo >&2
fi

log "Opening SSM tunnel localhost:$LOCAL_PORT -> $ALB_DNS:$ALB_PORT via $TEST_CLIENT_ID"
aws ssm start-session --target "$TEST_CLIENT_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ALB_DNS,portNumber=$ALB_PORT,localPortNumber=$LOCAL_PORT" >/dev/null 2>&1 &
TUNNEL=$!
trap 'kill $TUNNEL 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$LOCAL_PORT/health" && break; sleep 1; done

SCHEME="http"; [[ "$ALB_PORT" == "443" ]] && SCHEME="https"
BASE="$SCHEME://127.0.0.1:$LOCAL_PORT"
CURL=(curl -sS --max-time 60 -k)
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then log "PASS  $1"; PASS=$((PASS+1)); else warn "FAIL  $1 (expected $3, got $2)"; FAIL=$((FAIL+1)); fi; }

check "GET /health returns 200"            "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/health")" 200
check "GET /ready returns 200 (secrets OK)" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/ready")" 200
check "POST /v1/chat without key -> 401"   "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/chat" -H 'Content-Type: application/json' -d '{"message":"hi"}')" 401
RESP="$("${CURL[@]}" -w '\n%{http_code}' -X POST "$BASE/v1/chat" -H "X-API-Key: $CLIENT_API_KEY" -H 'Content-Type: application/json' \
  -d '{"message":"How do I reset my password?"}')"
check "POST /v1/chat with key -> 200"      "$(tail -n1 <<<"$RESP")" 200
if grep -q '"search_knowledge_base"' <<<"$RESP"; then
  log "PASS  agent used the knowledge-base tool"; PASS=$((PASS+1))
else
  warn "FAIL  agent did not call search_knowledge_base"; FAIL=$((FAIL+1))
fi
log "Answer: $(head -n -1 <<<"$RESP" | jq -r .answer 2>/dev/null | head -c 300)"
log "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
