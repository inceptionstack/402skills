# x402 Payments-Aware Browse Protocol

## Behavioral Contract

When the agent fetches any URL (via `curl`, `web_fetch`, or equivalent), it MUST be prepared to handle HTTP 402 responses transparently.

---

## Decision Flow

```
┌─────────────────────────────┐
│  Agent fetches a URL        │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  HTTP status code?          │
├─────────┬───────────────────┤
│  200    │  Content served   │──► Done
│  402    │  Payment required │──► Continue below
│  Other  │  Normal error     │──► Handle normally
└─────────┴───────────────────┘
               ▼
┌─────────────────────────────┐
│  Has `payment-required`     │
│  header?                    │
├────────┬────────────────────┤
│  No    │ Not x402 — normal  │──► Report 402 to user
│  Yes   │ x402 challenge     │──► Continue
└────────┴────────────────────┘
               ▼
┌─────────────────────────────┐
│  Is ~/.x402/config.json     │
│  present and valid?         │
├────────┬────────────────────┤
│  No    │ Cannot pay         │──► Tell user to run setup
│  Yes   │ Config loaded      │──► Continue
└────────┴────────────────────┘
               ▼
┌─────────────────────────────┐
│  Run x402-fetch.sh <url>    │
│  (full payment flow)        │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  Success?                   │
├────────┬────────────────────┤
│  Yes   │ Return content     │──► Done
│  No    │ Payment failed     │──► Report error to user
└────────┴────────────────────┘
```

---

## Agent Behavior Rules

### MUST

1. **Always probe first.** Never send payment headers speculatively.
2. **Use `x402-fetch.sh`** for the full flow — don't hand-roll curl commands inline unless debugging.
3. **Report costs.** Before paying, tell the user: "This URL requires x402 payment of {amount} {asset} on {network}. Proceed?"
4. **Respect dry-run.** If user says "just check" or "don't pay", use `--dry-run`.
5. **Clean up temp files.** The script handles this, but verify `/tmp/x402_*` doesn't accumulate.

### MUST NOT

1. **Never reuse a stale proof.** Each attempt needs a fresh `ProcessPayment` call.
2. **Never send payment to non-402 URLs.** Only pay when challenged.
3. **Never cache payment headers across requests.** Each request is independent.
4. **Never expose proof data to the user** unless they explicitly ask for debug info.
5. **Never pay without confirmation** unless the user has set auto-pay mode.

### SHOULD

1. **Use `--verbose`** when debugging failures — it shows the full challenge and proof.
2. **Check session status** (`x402-status.sh`) if payments keep failing.
3. **Renew proactively** (`x402-renew.sh`) if session is near expiry.
4. **Prefer the reliable test endpoint** (`d2ibe85pfj1pv3.cloudfront.net`) for smoke tests.

---

## Auto-Pay vs Confirmation Mode

By default, the agent MUST ask before paying. To enable auto-pay:

```bash
# In ~/.x402/config.json, add:
{
  "auto_pay": true,
  "auto_pay_max_amount": "0.01"
}
```

When `auto_pay` is true AND the requested amount ≤ `auto_pay_max_amount`, the agent may proceed without asking. Otherwise, always confirm.

---

## Error Recovery

| Failure | Agent Action |
|---------|-------------|
| Config missing | Tell user: "x402 not configured. Run `scripts/setup.sh` to set up." |
| Session expired | Run `x402-renew.sh`, retry once |
| 3 retries exhausted | Report failure, suggest trying later |
| Unknown network/asset | Report: "Unsupported payment network: {network}" |
| AWS credentials invalid | Tell user to check IAM / instance profile |

---

## Integration with web_fetch

When the agent uses `web_fetch` and gets a 402:

1. The tool may not expose headers — fall back to `curl -s -D -` for the probe.
2. Run `x402-fetch.sh` with the URL to handle payment.
3. Return the paid content as if `web_fetch` succeeded.

---

## Logging

All payment activity is logged to stderr (visible in `--verbose` mode):
- Timestamp
- URL accessed
- Amount paid
- Network/asset
- Success/failure
- Number of retries needed

The agent should note successful payments in session context so it doesn't re-probe URLs already known to require payment.
