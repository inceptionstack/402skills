#!/usr/bin/env bash
# x402-status.sh — Check x402 payment session and wallet status
# Dependencies: bash 4+, curl 7.75+, jq, aws cli 2.x
set -euo pipefail

CONFIG_FILE="${X402_CONFIG:-$HOME/.x402/config.json}"

# --- Colors ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

log() { echo -e "${BLUE}[x402]${NC} $*"; }
err() { echo -e "${RED}[x402]${NC} $*" >&2; }

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

# --- Print config summary ---
echo -e "\n${BOLD}=== x402 Configuration ===${NC}\n"
echo -e "  Config file:     $CONFIG_FILE"
echo -e "  Region:          $REGION"
echo -e "  Payment Manager: $PAYMENT_MANAGER_ID"
echo -e "  Instrument:      $PAYMENT_INSTRUMENT_ID"
echo -e "  Session:         $PAYMENT_SESSION_ID"
echo -e "  User ID:         $USER_ID"

# --- Check AWS identity ---
echo -e "\n${BOLD}=== AWS Identity ===${NC}\n"
AWS_IDENTITY=$(aws sts get-caller-identity 2>/dev/null || echo '{"error": "failed"}')
if echo "$AWS_IDENTITY" | jq -e '.Account' >/dev/null 2>&1; then
  echo -e "  Account: $(echo "$AWS_IDENTITY" | jq -r '.Account')"
  echo -e "  ARN:     $(echo "$AWS_IDENTITY" | jq -r '.Arn')"
  echo -e "  Status:  ${GREEN}✓ Valid${NC}"
else
  echo -e "  Status:  ${RED}✗ Invalid credentials${NC}"
  exit 1
fi

# --- Check payment session status ---
echo -e "\n${BOLD}=== Payment Session ===${NC}\n"

SESSION_RESPONSE=$(curl -s -X GET \
  "${ENDPOINT}/payment-managers/${PAYMENT_MANAGER_ID}/sessions/${PAYMENT_SESSION_ID}" \
  --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
  -H "Content-Type: application/json" \
  2>/dev/null) || SESSION_RESPONSE='{"error": "request_failed"}'

if echo "$SESSION_RESPONSE" | jq -e '.status // .state' >/dev/null 2>&1; then
  STATUS=$(echo "$SESSION_RESPONSE" | jq -r '.status // .state // "unknown"')
  EXPIRES=$(echo "$SESSION_RESPONSE" | jq -r '.expiresAt // .expiration // "unknown"')
  BALANCE=$(echo "$SESSION_RESPONSE" | jq -r '.balance // .remainingBalance // "unknown"')

  case "$STATUS" in
    active|ACTIVE)
      echo -e "  Status:  ${GREEN}✓ Active${NC}" ;;
    expired|EXPIRED)
      echo -e "  Status:  ${RED}✗ Expired${NC}"
      echo -e "  Action:  Run ./x402-renew.sh to renew" ;;
    *)
      echo -e "  Status:  ${YELLOW}? $STATUS${NC}" ;;
  esac

  [[ "$EXPIRES" != "unknown" && "$EXPIRES" != "null" ]] && echo -e "  Expires: $EXPIRES"
  [[ "$BALANCE" != "unknown" && "$BALANCE" != "null" ]] && echo -e "  Balance: $BALANCE"
elif echo "$SESSION_RESPONSE" | jq -e '.message' >/dev/null 2>&1; then
  echo -e "  Status:  ${YELLOW}? Cannot query${NC}"
  echo -e "  Detail:  $(echo "$SESSION_RESPONSE" | jq -r '.message')"
  echo -e "  Note:    Session query API may not be available; payment may still work"
else
  echo -e "  Status:  ${YELLOW}? Cannot determine${NC}"
  echo -e "  Note:    Session status endpoint may not be available yet"
  echo -e "  Hint:    Try a test payment with: ./x402-fetch.sh --dry-run <url>"
fi

# --- Check instrument ---
echo -e "\n${BOLD}=== Payment Instrument ===${NC}\n"

INSTRUMENT_RESPONSE=$(curl -s -X GET \
  "${ENDPOINT}/payment-managers/${PAYMENT_MANAGER_ID}/instruments/${PAYMENT_INSTRUMENT_ID}" \
  --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
  -H "Content-Type: application/json" \
  2>/dev/null) || INSTRUMENT_RESPONSE='{"error": "request_failed"}'

if echo "$INSTRUMENT_RESPONSE" | jq -e '.type // .instrumentType' >/dev/null 2>&1; then
  INST_TYPE=$(echo "$INSTRUMENT_RESPONSE" | jq -r '.type // .instrumentType // "unknown"')
  INST_NETWORK=$(echo "$INSTRUMENT_RESPONSE" | jq -r '.network // .chain // "unknown"')
  INST_ADDRESS=$(echo "$INSTRUMENT_RESPONSE" | jq -r '.address // .walletAddress // "unknown"')

  echo -e "  Type:    $INST_TYPE"
  [[ "$INST_NETWORK" != "unknown" && "$INST_NETWORK" != "null" ]] && echo -e "  Network: $INST_NETWORK"
  [[ "$INST_ADDRESS" != "unknown" && "$INST_ADDRESS" != "null" ]] && echo -e "  Address: $INST_ADDRESS"
  echo -e "  Status:  ${GREEN}✓ Found${NC}"
elif echo "$INSTRUMENT_RESPONSE" | jq -e '.message' >/dev/null 2>&1; then
  echo -e "  Status:  ${YELLOW}? Cannot query${NC}"
  echo -e "  Detail:  $(echo "$INSTRUMENT_RESPONSE" | jq -r '.message')"
else
  echo -e "  Status:  ${YELLOW}? Cannot determine${NC}"
  echo -e "  Note:    Instrument query API may not be available yet"
fi

# --- Connectivity check ---
echo -e "\n${BOLD}=== Connectivity ===${NC}\n"

# Test reachability of AgentCore endpoint
if curl -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/health" 2>/dev/null | grep -q "^[234]"; then
  echo -e "  AgentCore endpoint: ${GREEN}✓ Reachable${NC}"
else
  # Not all endpoints have /health — try the base
  CONNECT_TEST=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$ENDPOINT" 2>/dev/null || echo "000")
  if [[ "$CONNECT_TEST" != "000" ]]; then
    echo -e "  AgentCore endpoint: ${GREEN}✓ Reachable${NC} (HTTP $CONNECT_TEST)"
  else
    echo -e "  AgentCore endpoint: ${RED}✗ Unreachable${NC}"
  fi
fi

echo ""
log "Status check complete"
