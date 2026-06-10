#!/usr/bin/env bash
# x402-renew.sh — Renew an expired x402 payment session
# Dependencies: bash 4+, curl 7.75+, jq, aws cli 2.x
set -euo pipefail

CONFIG_FILE="${X402_CONFIG:-$HOME/.x402/config.json}"

# --- Colors ---
if [[ -t 2 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()  { echo -e "${BLUE}[x402]${NC} $*" >&2; }
err()  { echo -e "${RED}[x402]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[x402]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[x402]${NC} $*" >&2; }

# --- Load config ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Config not found: $CONFIG_FILE"
  err "Run: ~/.openclaw/workspace/skills/x402-payments/scripts/setup.sh"
  exit 1
fi

REGION=$(jq -r '.region // "us-east-1"' "$CONFIG_FILE")
PAYMENT_MANAGER_ARN=$(jq -r '.payment_manager_arn' "$CONFIG_FILE")
PAYMENT_INSTRUMENT_ID=$(jq -r '.payment_instrument_id' "$CONFIG_FILE")
PAYMENT_SESSION_ID=$(jq -r '.payment_session_id' "$CONFIG_FILE")
USER_ID=$(jq -r '.user_id' "$CONFIG_FILE")
PAYMENT_MANAGER_ID=$(echo "$PAYMENT_MANAGER_ARN" | grep -o '[^/]*$')

# --- Get AWS credentials ---
eval $(aws configure export-credentials --format env 2>/dev/null) || true
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  err "Cannot obtain AWS credentials"
  exit 1
fi

ENDPOINT="https://bedrock-agentcore.${REGION}.amazonaws.com"

log "Renewing payment session: $PAYMENT_SESSION_ID"

# --- Option 1: Try to renew existing session ---
RENEW_BODY=$(jq -n \
  --arg sessionId "$PAYMENT_SESSION_ID" \
  --arg instrumentId "$PAYMENT_INSTRUMENT_ID" \
  --arg userId "$USER_ID" \
  '{
    paymentSessionId: $sessionId,
    paymentInstrumentId: $instrumentId,
    userId: $userId
  }')

RENEW_RESPONSE=$(curl -s -X POST \
  "${ENDPOINT}/payment-managers/${PAYMENT_MANAGER_ID}/sessions/${PAYMENT_SESSION_ID}/renew" \
  --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
  -H "Content-Type: application/json" \
  -d "$RENEW_BODY" \
  -w "\n%{http_code}" 2>/dev/null)

HTTP_CODE=$(echo "$RENEW_RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RENEW_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  ok "✅ Session renewed successfully"

  # Update config if new session ID returned
  NEW_SESSION_ID=$(echo "$RESPONSE_BODY" | jq -r '.paymentSessionId // .sessionId // empty')
  NEW_EXPIRES=$(echo "$RESPONSE_BODY" | jq -r '.expiresAt // .expiration // empty')

  if [[ -n "$NEW_SESSION_ID" && "$NEW_SESSION_ID" != "$PAYMENT_SESSION_ID" ]]; then
    log "New session ID: $NEW_SESSION_ID"
    # Update config file with new session ID
    jq --arg sid "$NEW_SESSION_ID" '.payment_session_id = $sid' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Config updated with new session ID"
  fi

  [[ -n "$NEW_EXPIRES" ]] && log "Expires: $NEW_EXPIRES"
  exit 0
fi

# --- Option 2: Try creating a new session ---
warn "Renew endpoint returned HTTP $HTTP_CODE — trying to create a new session..."

CREATE_BODY=$(jq -n \
  --arg instrumentId "$PAYMENT_INSTRUMENT_ID" \
  --arg userId "$USER_ID" \
  '{
    paymentInstrumentId: $instrumentId,
    userId: $userId
  }')

CREATE_RESPONSE=$(curl -s -X POST \
  "${ENDPOINT}/payment-managers/${PAYMENT_MANAGER_ID}/sessions" \
  --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
  -H "Content-Type: application/json" \
  -d "$CREATE_BODY" \
  -w "\n%{http_code}" 2>/dev/null)

HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  NEW_SESSION_ID=$(echo "$RESPONSE_BODY" | jq -r '.paymentSessionId // .sessionId // empty')

  if [[ -n "$NEW_SESSION_ID" ]]; then
    ok "✅ New session created: $NEW_SESSION_ID"
    # Update config
    jq --arg sid "$NEW_SESSION_ID" '.payment_session_id = $sid' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Config updated with new session ID"
  else
    ok "✅ Session creation succeeded (using existing session ID)"
  fi

  NEW_EXPIRES=$(echo "$RESPONSE_BODY" | jq -r '.expiresAt // .expiration // empty')
  [[ -n "$NEW_EXPIRES" ]] && log "Expires: $NEW_EXPIRES"
  exit 0
fi

# --- Both failed ---
err "❌ Session renewal failed"
err "Renew response (HTTP $HTTP_CODE): $RESPONSE_BODY"
err ""
err "Possible fixes:"
err "  1. Check AWS credentials: aws sts get-caller-identity"
err "  2. Verify payment manager ARN in config"
err "  3. Re-run setup: ~/.openclaw/workspace/skills/x402-payments/scripts/setup.sh"
exit 1
