# x402-payments — Shell-Based HTTP Payment Skill

## Overview

x402 is an HTTP payment protocol. When a server returns **HTTP 402** with a `payment-required` header, it's requesting payment before serving content. This skill handles the full flow using only `bash`, `curl`, `jq`, `aws` CLI, and `base64`.

**No Python. No Node. Pure shell.**

---

## When to Trigger

Activate this skill when:
- A `curl` or `web_fetch` returns HTTP 402
- The response includes a `payment-required` header (base64-encoded JSON challenge)
- The user asks to access paid/monetized content via x402

---

## Prerequisites

| Tool | Version | Check |
|------|---------|-------|
| bash | 4.0+ | `bash --version` |
| curl | 7.75+ (needs `--aws-sigv4`) | `curl --version` |
| jq | 1.6+ | `jq --version` |
| aws | 2.x | `aws --version` |
| base64 | any | `base64 --version` or `which base64` |

### Config File

Located at `~/.x402/config.json` (permissions: `0600`):

```json
{
  "region": "us-east-1",
  "payment_manager_arn": "arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:payment-manager/NAME",
  "payment_instrument_id": "payment-instrument-XXXXX",
  "payment_session_id": "payment-session-XXXXX",
  "user_id": "your-user-id"
}
```

> **NEVER store private keys here.** AWS Bedrock AgentCore manages custody.

### First-Time Setup

Run the interactive onboarding wizard:
```bash
~/.openclaw/workspace/skills/x402-payments/scripts/setup.sh
```

---

## Protocol (Step-by-Step)

### Step 1: Probe the URL

```bash
RESPONSE=$(curl -s -D - -o /tmp/x402_body.txt "$TARGET_URL")
HTTP_CODE=$(echo "$RESPONSE" | grep -i "^HTTP/" | tail -1 | awk '{print $2}')
```

If `HTTP_CODE` is not `402`, the content is free — no payment needed.

### Step 2: Extract the Challenge

```bash
CHALLENGE_B64=$(echo "$RESPONSE" | grep -i "^payment-required:" | sed 's/^[^:]*: *//' | tr -d '\r\n')
CHALLENGE=$(echo "$CHALLENGE_B64" | base64 -d 2>/dev/null || echo "$CHALLENGE_B64" | base64 -D 2>/dev/null)
```

Parse fields with jq:
```bash
NETWORK=$(echo "$CHALLENGE" | jq -r '.network // .accepts[0].network')
AMOUNT=$(echo "$CHALLENGE" | jq -r '.maxAmountRequired // .accepts[0].maxAmountRequired')
ASSET=$(echo "$CHALLENGE" | jq -r '.asset // .accepts[0].asset')
PAY_TO=$(echo "$CHALLENGE" | jq -r '.payTo // .accepts[0].payTo')
EXTRA=$(echo "$CHALLENGE" | jq -r '.extra // .accepts[0].extra // empty')
```

### Step 3: Call ProcessPayment (AWS Bedrock AgentCore)

```bash
# Load config
CONFIG=$(cat ~/.x402/config.json)
REGION=$(echo "$CONFIG" | jq -r '.region')
PM_ARN=$(echo "$CONFIG" | jq -r '.payment_manager_arn')
INSTRUMENT_ID=$(echo "$CONFIG" | jq -r '.payment_instrument_id')
SESSION_ID=$(echo "$CONFIG" | jq -r '.payment_session_id')
USER_ID=$(echo "$CONFIG" | jq -r '.user_id')

# Extract payment manager ID from ARN
PM_ID=$(echo "$PM_ARN" | grep -o '[^/]*$')

# Build request body
REQUEST_BODY=$(jq -n \
  --arg instrumentId "$INSTRUMENT_ID" \
  --arg sessionId "$SESSION_ID" \
  --arg userId "$USER_ID" \
  --arg network "$NETWORK" \
  --arg amount "$AMOUNT" \
  --arg asset "$ASSET" \
  --arg payTo "$PAY_TO" \
  --arg extra "$EXTRA" \
  '{
    paymentInstrumentId: $instrumentId,
    paymentSessionId: $sessionId,
    userId: $userId,
    network: $network,
    amount: $amount,
    asset: $asset,
    payTo: $payTo,
    extra: (if $extra == "" then null else $extra end)
  }')

# Get AWS credentials from environment or instance profile
eval $(aws configure export-credentials --format env 2>/dev/null || true)

# Call ProcessPayment via curl with SigV4
ENDPOINT="https://bedrock-agentcore.${REGION}.amazonaws.com"
PAYMENT_RESPONSE=$(curl -s -X POST \
  "${ENDPOINT}/payment-managers/${PM_ID}/process-payment" \
  --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

PROOF=$(echo "$PAYMENT_RESPONSE" | jq -r '.proof // .signedPayload // .payment')
```

### Step 4: Build the x402 v2 PaymentPayload

The payload must include an `accepted` field echoing back the payment requirements:

```bash
PAYMENT_PAYLOAD=$(jq -n \
  --arg proof "$PROOF" \
  --arg network "$NETWORK" \
  --arg amount "$AMOUNT" \
  --arg asset "$ASSET" \
  --arg payTo "$PAY_TO" \
  --arg extra "$EXTRA" \
  '{
    version: "2",
    proof: $proof,
    accepted: {
      network: $network,
      maxAmountRequired: $amount,
      asset: $asset,
      payTo: $payTo,
      extra: (if $extra == "" then null else $extra end)
    }
  }')

# Base64-encode (cross-platform)
if [[ "$(uname)" == "Darwin" ]]; then
  PAYMENT_B64=$(echo -n "$PAYMENT_PAYLOAD" | base64)
else
  PAYMENT_B64=$(echo -n "$PAYMENT_PAYLOAD" | base64 -w0)
fi
```

### Step 5: Retry with Payment Header

**Important:** Wait 2 seconds past `validAfter` if present, and use a fresh request (no cookies).

```bash
sleep 2
RESULT=$(curl -s -D /tmp/x402_resp_headers.txt \
  -H "PAYMENT-SIGNATURE: ${PAYMENT_B64}" \
  "$TARGET_URL")
```

### Step 6: Handle Retries

Facilitators can be flaky. Retry up to 3 times with fresh proofs:

```bash
for attempt in 1 2 3; do
  # ... steps 3-5 ...
  RESULT_CODE=$(grep -i "^HTTP/" /tmp/x402_resp_headers.txt | tail -1 | awk '{print $2}')
  if [[ "$RESULT_CODE" == "200" ]]; then
    break
  fi
  sleep $((attempt * 2))
done
```

---

## Using the Script

The `x402-fetch.sh` script wraps this entire flow:

```bash
# Fetch paid content
./x402-fetch.sh https://d2ibe85pfj1pv3.cloudfront.net/monetize

# Dry run — inspect the challenge without paying
./x402-fetch.sh --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize

# Verbose mode
./x402-fetch.sh --verbose https://d2ibe85pfj1pv3.cloudfront.net/monetize
```

---

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `x402-fetch.sh` | Full payment flow — fetch paid content |
| `x402-status.sh` | Check wallet/session status |
| `x402-renew.sh` | Renew expired payment session |
| `scripts/setup.sh` | Interactive onboarding wizard |

---

## Testing

### Quick Smoke Test

```bash
# 1. Verify prerequisites
jq --version && curl --version | head -1 && aws --version

# 2. Verify config exists
cat ~/.x402/config.json | jq .

# 3. Dry run against test endpoint
./x402-fetch.sh --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize

# 4. Full payment test (costs 0.001 USDC on Base Sepolia testnet)
./x402-fetch.sh https://d2ibe85pfj1pv3.cloudfront.net/monetize
```

### Test Endpoints

| Endpoint | Cost | Network | Notes |
|----------|------|---------|-------|
| `https://d2ibe85pfj1pv3.cloudfront.net/monetize` | 0.001 USDC | Base Sepolia | Reliable |
| `https://sandbox.node4all.com/v1/x402-test` | 0.002 USDC | Base Sepolia | Flaky, needs retries |

### Expected Output (Success)

```
[x402] Probing https://d2ibe85pfj1pv3.cloudfront.net/monetize...
[x402] Got 402 — payment required
[x402] Challenge: network=base-sepolia amount=0.001 asset=USDC
[x402] Requesting payment proof from AgentCore...
[x402] Building v2 PaymentPayload...
[x402] Waiting for validAfter window...
[x402] Sending paid request (attempt 1/3)...
[x402] ✅ Success (HTTP 200) — content received
```

---

## Debugging

| Symptom | Cause | Fix |
|---------|-------|-----|
| `jq: command not found` | Missing jq | `sudo yum install jq` / `brew install jq` |
| `--aws-sigv4 unknown option` | curl too old (<7.75) | Upgrade curl or use `aws` CLI fallback |
| `403` from AgentCore | Bad credentials or wrong ARN | Check `aws sts get-caller-identity`, verify ARN |
| `402` persists after payment | Stale proof / timing | Script auto-retries; check validAfter logic |
| `Invalid payment signature` | Wrong header format | Ensure `PAYMENT-SIGNATURE` (not `X-PAYMENT`) |
| `Session expired` | Payment session timed out | Run `./x402-renew.sh` |
| Config permission denied | Wrong file perms | `chmod 600 ~/.x402/config.json` |
| base64 errors on macOS | Flag incompatibility | Script auto-detects OS; don't use `-w0` on macOS |

---

## Security Notes

- **No private keys on disk.** AWS Bedrock AgentCore holds custody.
- Config file at `~/.x402/config.json` must be `0600` (owner-read/write only).
- Temporary files in `/tmp/x402_*` are cleaned up after each run.
- AWS credentials sourced from instance profile / environment — never hardcoded.
- All test endpoints use **testnet** tokens (Base Sepolia) — no real money.
