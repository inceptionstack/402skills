#!/usr/bin/env bash
# x402-fetch.sh — Fetch paid content via x402 HTTP payment protocol
# Dependencies: bash 4+, curl 7.75+ (--aws-sigv4), jq 1.6+, aws cli 2.x, base64
# Usage: ./x402-fetch.sh [--dry-run] [--verbose] [--output FILE] <url>
set -euo pipefail

# --- Configuration ---
CONFIG_FILE="${X402_CONFIG:-$HOME/.x402/config.json}"
MAX_RETRIES=3
VALID_AFTER_BUFFER=2
TMPDIR="${TMPDIR:-/tmp}"

# --- Colors (disabled if not a terminal) ---
if [[ -t 2 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# --- Globals ---
DRY_RUN=false
VERBOSE=false
OUTPUT_FILE=""
TARGET_URL=""

# --- Helpers ---
log()   { echo -e "${BLUE}[x402]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[x402]${NC} $*" >&2; }
err()   { echo -e "${RED}[x402]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[x402]${NC} $*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[x402 debug]${NC} $*" >&2 || true; }

cleanup() {
  rm -f "${TMPDIR}/x402_headers_$$" "${TMPDIR}/x402_body_$$" \
        "${TMPDIR}/x402_resp_headers_$$" "${TMPDIR}/x402_resp_body_$$" \
        "${TMPDIR}/x402_payment_resp_$$"
}
trap cleanup EXIT

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS] <url>

Fetch content from an x402-enabled URL, handling payment transparently.

Options:
  --dry-run     Show the payment challenge without paying
  --verbose     Show detailed debug output
  --output FILE Write response body to FILE instead of stdout
  -h, --help    Show this help

Examples:
  $(basename "$0") https://d2ibe85pfj1pv3.cloudfront.net/monetize
  $(basename "$0") --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize
EOF
  exit 1
}

# --- Base64 cross-platform ---
b64encode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64
  else
    base64 -w0
  fi
}

b64decode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64 -D
  else
    base64 -d
  fi
}

# --- Parse arguments ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=true; shift ;;
      --verbose)  VERBOSE=true; shift ;;
      --output)   OUTPUT_FILE="$2"; shift 2 ;;
      -h|--help)  usage ;;
      -*)         err "Unknown option: $1"; usage ;;
      *)          TARGET_URL="$1"; shift ;;
    esac
  done
  if [[ -z "$TARGET_URL" ]]; then
    err "No URL specified"
    usage
  fi
}

# --- Load config ---
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config not found: $CONFIG_FILE"
    err ""
    err "First-time setup needed:"
    err "  1. Get Coinbase CDP API key from https://portal.cdp.coinbase.com/"
    err "  2. Run: $(dirname "$0")/scripts/setup.sh"
    err "  3. Visit the delegation URL and grant signing permission"
    err "  4. Fund wallet at https://faucet.circle.com/ (Base Sepolia)"
    exit 1
  fi

  REGION=$(jq -r '.region // "us-east-1"' "$CONFIG_FILE")
  PAYMENT_MANAGER_ARN=$(jq -r '.payment_manager_arn' "$CONFIG_FILE")
  PAYMENT_INSTRUMENT_ID=$(jq -r '.payment_instrument_id' "$CONFIG_FILE")
  PAYMENT_SESSION_ID=$(jq -r '.payment_session_id' "$CONFIG_FILE")
  USER_ID=$(jq -r '.user_id' "$CONFIG_FILE")

  if [[ -z "$PAYMENT_MANAGER_ARN" || "$PAYMENT_MANAGER_ARN" == "null" ]]; then
    err "Invalid config: payment_manager_arn missing"
    exit 1
  fi

  debug "Config: region=$REGION instrument=$PAYMENT_INSTRUMENT_ID"
}

# --- Get AWS credentials ---
get_aws_creds() {
  eval $(aws configure export-credentials --format env 2>/dev/null) || true
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    err "Cannot obtain AWS credentials. Check IAM role or aws configure."
    exit 1
  fi
  debug "AWS credentials loaded"
}

# --- Probe the URL ---
probe_url() {
  log "Probing ${TARGET_URL}..."

  curl -sS -D "${TMPDIR}/x402_headers_$$" -o "${TMPDIR}/x402_body_$$" \
    -L "$TARGET_URL"

  local http_code
  http_code=$(grep -i "^HTTP/" "${TMPDIR}/x402_headers_$$" | tail -1 | awk '{print $2}')

  if [[ "$http_code" == "200" ]]; then
    log "Content is free (HTTP 200)"
    cat "${TMPDIR}/x402_body_$$"
    exit 0
  elif [[ "$http_code" != "402" ]]; then
    err "HTTP $http_code — not a payment challenge"
    exit 1
  fi

  log "Got 402 — payment required"
}

# --- Parse x402 challenge ---
parse_challenge() {
  local challenge_b64
  challenge_b64=$(grep -i "^payment-required:" "${TMPDIR}/x402_headers_$$" | sed 's/^[^:]*: *//' | tr -d '\r\n')

  if [[ -z "$challenge_b64" ]]; then
    err "No payment-required header — not an x402 endpoint"
    exit 1
  fi

  CHALLENGE=$(echo "$challenge_b64" | b64decode 2>/dev/null) || CHALLENGE="$challenge_b64"

  if ! echo "$CHALLENGE" | jq . >/dev/null 2>&1; then
    err "Cannot parse challenge as JSON"
    exit 1
  fi

  # Extract from accepts[0] (x402 v2 format)
  if echo "$CHALLENGE" | jq -e '.accepts[0]' >/dev/null 2>&1; then
    X402_VERSION=$(echo "$CHALLENGE" | jq -r '.x402Version // 2')
    SCHEME=$(echo "$CHALLENGE" | jq -r '.accepts[0].scheme // "exact"')
    NETWORK=$(echo "$CHALLENGE" | jq -r '.accepts[0].network')
    AMOUNT=$(echo "$CHALLENGE" | jq -r '.accepts[0].amount // .accepts[0].maxAmountRequired // "0"')
    ASSET=$(echo "$CHALLENGE" | jq -r '.accepts[0].asset')
    PAY_TO=$(echo "$CHALLENGE" | jq -r '.accepts[0].payTo')
    MAX_TIMEOUT=$(echo "$CHALLENGE" | jq -r '.accepts[0].maxTimeoutSeconds // 60')
    EXTRA=$(echo "$CHALLENGE" | jq -c '.accepts[0].extra // null')
    RESOURCE=$(echo "$CHALLENGE" | jq -c '.resource // null')
  else
    err "Challenge missing 'accepts' array — unsupported format"
    exit 1
  fi

  log "Challenge: network=$NETWORK amount=$AMOUNT payTo=${PAY_TO:0:12}..."
  debug "scheme=$SCHEME asset=$ASSET maxTimeout=$MAX_TIMEOUT"
  [[ "$EXTRA" != "null" ]] && debug "extra=$EXTRA"
}

# --- Dry-run output ---
show_dry_run() {
  echo "$CHALLENGE" | jq '{
    x402Version: .x402Version,
    network: .accepts[0].network,
    amount: (.accepts[0].amount // .accepts[0].maxAmountRequired),
    asset: .accepts[0].asset,
    payTo: .accepts[0].payTo,
    scheme: .accepts[0].scheme,
    extra: .accepts[0].extra,
    resource: .resource
  }'
  exit 0
}

# --- Call ProcessPayment via AWS API ---
call_process_payment() {
  log "Calling ProcessPayment..."

  # Build the paymentInput (matches the actual boto3 API format)
  local payment_payload
  payment_payload=$(jq -n \
    --arg scheme "$SCHEME" \
    --arg network "$NETWORK" \
    --arg amount "$AMOUNT" \
    --arg asset "$ASSET" \
    --arg payTo "$PAY_TO" \
    --argjson maxTimeout "$MAX_TIMEOUT" \
    --argjson extra "$EXTRA" \
    '{
      scheme: $scheme,
      network: $network,
      amount: $amount,
      asset: $asset,
      payTo: $payTo,
      maxTimeoutSeconds: $maxTimeout
    } + (if $extra != null then {extra: $extra} else {} end)')

  local request_body
  request_body=$(jq -n \
    --arg pmArn "$PAYMENT_MANAGER_ARN" \
    --arg instrumentId "$PAYMENT_INSTRUMENT_ID" \
    --arg sessionId "$PAYMENT_SESSION_ID" \
    --arg version "$X402_VERSION" \
    --argjson payload "$payment_payload" \
    '{
      paymentManagerArn: $pmArn,
      paymentInstrumentId: $instrumentId,
      paymentSessionId: $sessionId,
      paymentType: "CRYPTO_X402",
      paymentInput: {
        cryptoX402: {
          version: ($version | tostring),
          payload: $payload
        }
      }
    }')

  debug "ProcessPayment body: $request_body"

  # Call the API via curl with SigV4
  local endpoint="https://bedrock-agentcore.${REGION}.amazonaws.com"

  curl -sS -X POST \
    "${endpoint}/payments/processPayment" \
    --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: ${AWS_SESSION_TOKEN}"} \
    -H "Content-Type: application/json" \
    -H "X-Amzn-Bedrock-AgentCore-Payments-User-Id: ${USER_ID}" \
    -d "$request_body" \
    -o "${TMPDIR}/x402_payment_resp_$$"

  local payment_resp
  payment_resp=$(cat "${TMPDIR}/x402_payment_resp_$$")
  debug "ProcessPayment response: $payment_resp"

  # Check for errors
  if echo "$payment_resp" | jq -e '.__type // .error // .Error' >/dev/null 2>&1; then
    local error_msg
    error_msg=$(echo "$payment_resp" | jq -r '.message // .Message // .error // "unknown error"')
    err "ProcessPayment error: $error_msg"
    return 1
  fi

  # Extract signature + authorization from response
  SIGNATURE=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.signature')
  AUTH_FROM=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.from')
  AUTH_TO=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.to')
  AUTH_VALUE=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.value')
  AUTH_VALID_AFTER=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.validAfter')
  AUTH_VALID_BEFORE=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.validBefore')
  AUTH_NONCE=$(echo "$payment_resp" | jq -r '.paymentOutput.cryptoX402.payload.authorization.nonce')

  if [[ -z "$SIGNATURE" || "$SIGNATURE" == "null" ]]; then
    err "No signature in ProcessPayment response"
    debug "Full response: $payment_resp"
    return 1
  fi

  debug "Signature: ${SIGNATURE:0:20}..."
  debug "validAfter=$AUTH_VALID_AFTER validBefore=$AUTH_VALID_BEFORE"
  return 0
}

# --- Build x402 v2 proof ---
build_proof() {
  log "Building x402 v2 PaymentPayload..."

  # Build the exact v2 format: { x402Version, payload: {signature, authorization}, accepted }
  local proof
  proof=$(jq -n \
    --argjson version "$X402_VERSION" \
    --arg sig "$SIGNATURE" \
    --arg authFrom "$AUTH_FROM" \
    --arg authTo "$AUTH_TO" \
    --arg authValue "$AUTH_VALUE" \
    --arg authValidAfter "$AUTH_VALID_AFTER" \
    --arg authValidBefore "$AUTH_VALID_BEFORE" \
    --arg authNonce "$AUTH_NONCE" \
    --arg scheme "$SCHEME" \
    --arg network "$NETWORK" \
    --arg asset "$ASSET" \
    --arg amount "$AMOUNT" \
    --arg payTo "$PAY_TO" \
    --argjson maxTimeout "$MAX_TIMEOUT" \
    --argjson extra "$EXTRA" \
    --argjson resource "$RESOURCE" \
    '{
      x402Version: $version,
      payload: {
        signature: $sig,
        authorization: {
          from: $authFrom,
          to: $authTo,
          value: $authValue,
          validAfter: $authValidAfter,
          validBefore: $authValidBefore,
          nonce: $authNonce
        }
      },
      accepted: ({
        scheme: $scheme,
        network: $network,
        asset: $asset,
        amount: $amount,
        payTo: $payTo,
        maxTimeoutSeconds: $maxTimeout
      } + (if $extra != null then {extra: $extra} else {} end))
    } + (if $resource != null then {resource: $resource} else {} end)')

  debug "Proof JSON: $proof"

  # Base64 encode (compact JSON, no whitespace)
  PAYMENT_HEADER=$(echo -n "$proof" | jq -c . | b64encode)
  debug "PAYMENT-SIGNATURE header: ${#PAYMENT_HEADER} chars"
}

# --- Wait for validAfter ---
wait_valid_after() {
  local now va_ts wait_secs
  now=$(date +%s)
  va_ts="$AUTH_VALID_AFTER"

  if [[ -n "$va_ts" && "$va_ts" != "null" && "$va_ts" != "0" ]]; then
    wait_secs=$(( va_ts - now + VALID_AFTER_BUFFER ))
    if [[ $wait_secs -gt 0 && $wait_secs -lt 30 ]]; then
      log "Sleeping ${wait_secs}s past validAfter..."
      sleep "$wait_secs"
    else
      sleep "$VALID_AFTER_BUFFER"
    fi
  else
    sleep "$VALID_AFTER_BUFFER"
  fi
}

# --- Send paid request ---
send_paid_request() {
  local attempt=$1
  log "Sending paid request (attempt ${attempt}/${MAX_RETRIES})..."

  curl -sS \
    -D "${TMPDIR}/x402_resp_headers_$$" \
    -o "${TMPDIR}/x402_resp_body_$$" \
    -H "PAYMENT-SIGNATURE: ${PAYMENT_HEADER}" \
    -L "$TARGET_URL"

  local resp_code
  resp_code=$(grep -i "^HTTP/" "${TMPDIR}/x402_resp_headers_$$" | tail -1 | awk '{print $2}')

  if [[ "$resp_code" == "200" || "$resp_code" == "201" ]]; then
    return 0
  fi

  debug "Got HTTP $resp_code on attempt $attempt"
  return 1
}

# --- Main ---
main() {
  parse_args "$@"

  # Probe doesn't need config (dry-run works without credentials)
  probe_url
  parse_challenge

  if [[ "$DRY_RUN" == "true" ]]; then
    show_dry_run
  fi

  # From here we need config + AWS creds
  load_config
  get_aws_creds

  local success=false
  for attempt in $(seq 1 $MAX_RETRIES); do
    if call_process_payment; then
      build_proof
      wait_valid_after

      if send_paid_request "$attempt"; then
        success=true
        break
      fi
    fi

    if [[ $attempt -lt $MAX_RETRIES ]]; then
      warn "Attempt $attempt failed — retrying in $((attempt * 2))s..."
      sleep $((attempt * 2))
      # Re-probe for fresh challenge on retry
      probe_url
      parse_challenge
    fi
  done

  if [[ "$success" == "true" ]]; then
    ok "✅ Payment accepted (HTTP 200)"
    if [[ -n "$OUTPUT_FILE" ]]; then
      cp "${TMPDIR}/x402_resp_body_$$" "$OUTPUT_FILE"
      log "Written to: $OUTPUT_FILE"
    else
      cat "${TMPDIR}/x402_resp_body_$$"
    fi
  else
    err "❌ Payment failed after $MAX_RETRIES attempts"
    err "Try: ./x402-status.sh or ./x402-renew.sh"
    exit 1
  fi
}

main "$@"
