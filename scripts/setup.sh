#!/usr/bin/env bash
# setup.sh — Interactive onboarding wizard for x402-payments
# Creates ~/.x402/config.json with payment manager configuration
# Dependencies: bash 4+, jq, aws cli 2.x
set -euo pipefail

CONFIG_DIR="$HOME/.x402"
CONFIG_FILE="$CONFIG_DIR/config.json"

# --- Colors ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

log()  { echo -e "${BLUE}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }

header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  x402-payments Setup Wizard${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# --- Prerequisite check ---
check_prereqs() {
  log "Checking prerequisites..."
  local missing=()

  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v aws >/dev/null 2>&1 || missing+=("aws")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v base64 >/dev/null 2>&1 || missing+=("base64")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    echo ""
    echo "Install them:"
    for tool in "${missing[@]}"; do
      case "$tool" in
        jq)     echo "  • jq:   sudo yum install jq  /  brew install jq  /  sudo apt install jq" ;;
        aws)    echo "  • aws:  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
        curl)   echo "  • curl: sudo yum install curl  /  brew install curl" ;;
        base64) echo "  • base64: usually pre-installed (coreutils)" ;;
      esac
    done
    exit 1
  fi

  # Check curl version for --aws-sigv4
  local curl_version
  curl_version=$(curl --version | head -1 | awk '{print $2}')
  local major minor
  major=$(echo "$curl_version" | cut -d. -f1)
  minor=$(echo "$curl_version" | cut -d. -f2)
  if [[ $major -lt 7 || ($major -eq 7 && $minor -lt 75) ]]; then
    warn "curl $curl_version detected — --aws-sigv4 requires 7.75+"
    warn "Payment requests may fail. Consider upgrading curl."
  fi

  ok "All prerequisites met ✓"
}

# --- Check AWS access ---
check_aws() {
  log "Checking AWS credentials..."
  local identity
  identity=$(aws sts get-caller-identity 2>/dev/null || echo "")

  if [[ -z "$identity" ]]; then
    err "AWS credentials not configured or expired"
    echo ""
    echo "Options:"
    echo "  1. Running on EC2 with instance profile (recommended)"
    echo "  2. aws configure sso"
    echo "  3. Export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
    exit 1
  fi

  local account arn
  account=$(echo "$identity" | jq -r '.Account')
  arn=$(echo "$identity" | jq -r '.Arn')
  ok "AWS identity: $arn (account: $account)"
  echo ""

  AWS_ACCOUNT="$account"
}

# --- Prompt helper ---
prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local value

  if [[ -n "$default" ]]; then
    echo -ne "  ${prompt_text} [${default}]: "
  else
    echo -ne "  ${prompt_text}: "
  fi

  read -r value
  value="${value:-$default}"

  if [[ -z "$value" ]]; then
    err "Value required for: $prompt_text"
    exit 1
  fi

  eval "$var_name=\"$value\""
}

# --- Existing config ---
check_existing() {
  if [[ -f "$CONFIG_FILE" ]]; then
    warn "Existing config found: $CONFIG_FILE"
    echo ""
    echo "  Current config:"
    jq . "$CONFIG_FILE" | sed 's/^/    /'
    echo ""
    echo -ne "  Overwrite? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      log "Keeping existing config. Exiting."
      exit 0
    fi
    echo ""
  fi
}

# --- Discover existing resources ---
discover_resources() {
  log "Checking for existing Bedrock AgentCore payment resources..."
  echo ""

  # Try to list payment managers
  local endpoint="https://bedrock-agentcore.${REGION}.amazonaws.com"

  eval $(aws configure export-credentials --format env 2>/dev/null) || true

  local pm_list
  pm_list=$(curl -s -X GET \
    "${endpoint}/payment-managers" \
    --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
    -H "Content-Type: application/json" \
    2>/dev/null) || pm_list=""

  if echo "$pm_list" | jq -e '.paymentManagers[0]' >/dev/null 2>&1; then
    ok "Found existing payment manager(s):"
    echo "$pm_list" | jq -r '.paymentManagers[] | "    • \(.paymentManagerId // .id) (\(.name // "unnamed"))"'
    echo ""
    DISCOVERED_PM=$(echo "$pm_list" | jq -r '.paymentManagers[0].arn // .paymentManagers[0].paymentManagerArn // empty')
    return 0
  fi

  log "No existing payment managers found (or list API unavailable)"
  DISCOVERED_PM=""
  return 1
}

# --- Main wizard ---
main() {
  header
  check_prereqs
  check_aws
  check_existing

  echo -e "${BOLD}  Configure your x402 payment settings:${NC}"
  echo ""

  # Region
  prompt REGION "AWS Region" "us-east-1"
  echo ""

  # Try to discover existing resources
  discover_resources || true
  echo ""

  # Payment Manager ARN
  if [[ -n "${DISCOVERED_PM:-}" ]]; then
    prompt PM_ARN "Payment Manager ARN" "$DISCOVERED_PM"
  else
    echo "  (Format: arn:aws:bedrock-agentcore:REGION:ACCOUNT:payment-manager/NAME)"
    prompt PM_ARN "Payment Manager ARN" "arn:aws:bedrock-agentcore:${REGION}:${AWS_ACCOUNT}:payment-manager/"
  fi
  echo ""

  # Payment Instrument ID
  prompt INSTRUMENT_ID "Payment Instrument ID" ""
  echo ""

  # Payment Session ID
  prompt SESSION_ID "Payment Session ID" ""
  echo ""

  # User ID
  prompt USER_ID "User ID" "${USER:-$(whoami)}"
  echo ""

  # Auto-pay settings
  echo -ne "  Enable auto-pay for small amounts? (y/N): "
  read -r auto_pay_choice
  AUTO_PAY="false"
  AUTO_PAY_MAX="0.01"
  if [[ "$auto_pay_choice" == "y" || "$auto_pay_choice" == "Y" ]]; then
    AUTO_PAY="true"
    prompt AUTO_PAY_MAX "Max auto-pay amount (USDC)" "0.01"
  fi
  echo ""

  # --- Write config ---
  log "Writing config to $CONFIG_FILE..."

  mkdir -p "$CONFIG_DIR"

  jq -n \
    --arg region "$REGION" \
    --arg pmArn "$PM_ARN" \
    --arg instrumentId "$INSTRUMENT_ID" \
    --arg sessionId "$SESSION_ID" \
    --arg userId "$USER_ID" \
    --argjson autoPay "$AUTO_PAY" \
    --arg autoPayMax "$AUTO_PAY_MAX" \
    '{
      region: $region,
      payment_manager_arn: $pmArn,
      payment_instrument_id: $instrumentId,
      payment_session_id: $sessionId,
      user_id: $userId,
      auto_pay: $autoPay,
      auto_pay_max_amount: $autoPayMax
    }' > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"

  ok "✅ Config written to $CONFIG_FILE (permissions: 600)"
  echo ""

  # --- Verify ---
  echo -e "${BOLD}  Final config:${NC}"
  echo ""
  jq . "$CONFIG_FILE" | sed 's/^/    /'
  echo ""

  # --- Test connectivity ---
  log "Testing AgentCore connectivity..."
  local endpoint="https://bedrock-agentcore.${REGION}.amazonaws.com"
  local test_code
  test_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$endpoint" 2>/dev/null || echo "000")
  if [[ "$test_code" != "000" ]]; then
    ok "AgentCore endpoint reachable ✓"
  else
    warn "Cannot reach AgentCore endpoint — check network/VPC config"
  fi

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  Setup complete!${NC}"
  echo ""
  echo "  Next steps:"
  echo "    1. Test: ./x402-fetch.sh --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize"
  echo "    2. Pay:  ./x402-fetch.sh https://d2ibe85pfj1pv3.cloudfront.net/monetize"
  echo "    3. Check: ./x402-status.sh"
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main "$@"
