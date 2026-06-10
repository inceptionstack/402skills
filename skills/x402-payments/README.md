# 402skills

x402 HTTP payment skill for AI agents. Pay for paywalled content automatically using AWS Bedrock AgentCore Payments.

**Pure bash.** No Python, no Node, no package managers.

## What it does

When a URL returns HTTP 402 with an x402 challenge, this skill:
1. Extracts the payment challenge (network, amount, asset, recipient)
2. Calls AWS Bedrock AgentCore `ProcessPayment` to sign an EIP-3009 authorization
3. Builds an x402 v2 proof with `PAYMENT-SIGNATURE` header
4. Retries the request — returns paid content on success

## Quick start

```bash
# Dry-run (inspect challenge, no payment)
./x402-fetch.sh --dry-run https://example.com/paid-endpoint

# Pay and fetch
./x402-fetch.sh https://example.com/paid-endpoint

# Check session status
./x402-status.sh

# Renew expired session
./x402-renew.sh
```

## Requirements

| Tool | Min version | Why |
|------|-------------|-----|
| bash | 4.0+ | arrays, `[[` |
| curl | 7.75+ | `--aws-sigv4` for SigV4 signing |
| jq | 1.6+ | JSON parsing |
| aws cli | 2.x | credential export |
| base64 | any | proof encoding |

## Setup

```bash
# First-time onboarding (interactive)
./scripts/setup.sh
```

This creates `~/.x402/config.json` with your AgentCore payment resource IDs.

You also need:
- AWS credentials (instance profile, SSO, or env vars)
- A funded wallet (testnet: https://faucet.circle.com/ → Base Sepolia)
- Delegation granted (visit the URL printed during instrument creation)

## Config

`~/.x402/config.json` (permissions 0600):

```json
{
  "region": "us-east-1",
  "payment_manager_arn": "arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:payment-manager/NAME",
  "payment_instrument_id": "payment-instrument-XXXXX",
  "payment_session_id": "payment-session-XXXXX",
  "user_id": "your-user-id"
}
```

Override path with `X402_CONFIG` env var.

## Agent integration

### For OpenClaw

Place this directory in `~/.openclaw/workspace/skills/x402-payments/`. The agent reads `SKILL.md` when it encounters a 402.

### For any agent

When your agent gets HTTP 402 with a `payment-required` header:

```bash
# One command — handles everything (retries, validAfter, proof format)
./x402-fetch.sh "https://the-url-that-returned-402"
```

Exit codes:
- `0` — success, content on stdout
- `1` — error (config missing, payment failed, etc.)

Stderr has human-readable progress logs. Stdout has only the paid content.

### Behavioral rules

- **Never pay silently.** Ask user before creating sessions.
- **Always probe first.** Don't send payment headers speculatively.
- **Retry on failure.** Facilitators are flaky — script retries 3x automatically.
- **Don't surface payment internals** unless user asks.

See `payments-aware-browse.md` for the full behavioral protocol.

## Files

| File | Purpose |
|------|---------|
| `x402-fetch.sh` | Main tool — probe, pay, fetch |
| `x402-status.sh` | Check session/wallet/connectivity |
| `x402-renew.sh` | Renew expired payment session |
| `scripts/setup.sh` | First-time onboarding wizard |
| `SKILL.md` | Skill trigger docs for OpenClaw |
| `payments-aware-browse.md` | Agent behavioral protocol |

## How it works

```
GET /resource → 402 + payment-required header (base64 JSON challenge)
                ↓
Parse: network, amount, asset, payTo, extra
                ↓
POST /payments/processPayment (AWS SigV4)
  Header: X-Amzn-Bedrock-AgentCore-Payments-User-Id
  Body: { paymentManagerArn, paymentInstrumentId, paymentSessionId,
          paymentType: "CRYPTO_X402",
          paymentInput: { cryptoX402: { version: "2", payload: {...} } } }
                ↓
Response: { paymentOutput: { cryptoX402: { payload: { signature, authorization } } } }
                ↓
Build proof: { x402Version: 2, payload: {signature, authorization},
               accepted: {scheme, network, asset, amount, payTo, maxTimeoutSeconds, extra} }
                ↓
Base64 encode → PAYMENT-SIGNATURE header
                ↓
Sleep 2s past validAfter (facilitators reject early submissions)
                ↓
GET /resource + PAYMENT-SIGNATURE header → 200 + content
```

## Testing

```bash
# Reliable test endpoint (0.001 USDC on Base Sepolia testnet)
./x402-fetch.sh https://d2ibe85pfj1pv3.cloudfront.net/monetize

# Flaky but functional (needs retries, 0.002 USDC)
./x402-fetch.sh https://sandbox.node4all.com/v1/x402-test
```

## License

MIT
