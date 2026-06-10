#!/usr/bin/env bash
# setup.sh — x402-payments onboarding (agent-friendly, non-interactive)
#
# Designed to be called by an AI agent during a chat conversation.
# All inputs via flags (no interactive prompts). JSON output for parsing.
# The agent reads stdout, decides what to tell the user, and calls next step.
#
# Usage:
#   ./setup.sh check              # Check prerequisites + existing config
#   ./setup.sh config \            # Write config directly (all values as flags)
#     --region us-east-1 \
#     --payment-manager-arn "arn:..." \
#     --payment-instrument-id "payment-instrument-XXX" \
#     --payment-session-id "payment-session-XXX" \
#     --user-id "myuser"
#   ./setup.sh verify             # Verify config works (dry-run a test endpoint)
#
# Exit codes:
#   0 — success
#   1 — error (details in JSON stdout)
#   2 — missing prerequisites (details in JSON stdout)
#
# Dependencies: bash 4+, curl 7.75+, jq, aws cli 2.x, base64
set -euo pipefail

CONFIG_DIR="$HOME/.x402"
CONFIG_FILE="${X402_CONFIG:-$CONFIG_DIR/config.json}"

# --- JSON output helpers ---
json_ok() {
  local msg="$1"; shift
  jq -n --arg status "ok" --arg message "$msg" "$@" '{status: $status, message: $message} + $ARGS.named'
}

json_error() {
  local msg="$1"; shift
  jq -n --arg status "error" --arg message "$msg" "$@" '{status: $status, message: $message} + $ARGS.named' 
  exit 1
}

json_info() {
  jq -n "$@"
}

# --- check: prerequisites + existing state ---
cmd_check() {
  local issues=()
  local tools_ok=true

  # Check tools
  command -v jq >/dev/null 2>&1 || issues+=("jq not installed (apt/yum/brew install jq)")
  command -v aws >/dev/null 2>&1 || issues+=("aws cli not installed (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)")
  command -v curl >/dev/null 2>&1 || issues+=("curl not installed")
  command -v base64 >/dev/null 2>&1 || issues+=("base64 not installed")

  # Check curl version
  local curl_version=""
  if command -v curl >/dev/null 2>&1; then
    curl_version=$(curl --version | head -1 | awk '{print $2}')
    local major minor
    major=$(echo "$curl_version" | cut -d. -f1)
    minor=$(echo "$curl_version" | cut -d. -f2)
    if [[ $major -lt 7 || ($major -eq 7 && $minor -lt 75) ]]; then
      issues+=("curl $curl_version too old — needs 7.75+ for --aws-sigv4")
    fi
  fi

  # Check AWS credentials
  local aws_ok=false
  local aws_account="" aws_arn=""
  if command -v aws >/dev/null 2>&1; then
    local identity
    identity=$(aws sts get-caller-identity 2>/dev/null || echo "")
    if [[ -n "$identity" ]]; then
      aws_ok=true
      aws_account=$(echo "$identity" | jq -r '.Account')
      aws_arn=$(echo "$identity" | jq -r '.Arn')
    else
      issues+=("AWS credentials not configured or expired — need instance profile, SSO, or env vars")
    fi
  fi

  # Check existing config
  local config_exists=false
  local config_valid=false
  if [[ -f "$CONFIG_FILE" ]]; then
    config_exists=true
    if jq . "$CONFIG_FILE" >/dev/null 2>&1; then
      config_valid=true
    fi
  fi

  # Check AgentCore endpoint reachability
  local endpoint_reachable=false
  if [[ "$aws_ok" == "true" ]]; then
    local region="${1:-us-east-1}"
    local test_code
    test_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      "https://bedrock-agentcore.${region}.amazonaws.com" 2>/dev/null || echo "000")
    [[ "$test_code" != "000" ]] && endpoint_reachable=true
  fi

  # Build JSON output
  local issues_json="[]"
  if [[ ${#issues[@]} -gt 0 ]]; then
    issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
  fi

  jq -n \
    --argjson issues "$issues_json" \
    --argjson aws_ok "$aws_ok" \
    --arg aws_account "$aws_account" \
    --arg aws_arn "$aws_arn" \
    --argjson config_exists "$config_exists" \
    --argjson config_valid "$config_valid" \
    --arg config_path "$CONFIG_FILE" \
    --arg curl_version "$curl_version" \
    --argjson endpoint_reachable "$endpoint_reachable" \
    '{
      status: (if ($issues | length) == 0 then "ready" else "issues" end),
      issues: $issues,
      aws: {ok: $aws_ok, account: $aws_account, arn: $aws_arn},
      config: {exists: $config_exists, valid: $config_valid, path: $config_path},
      curl_version: $curl_version,
      endpoint_reachable: $endpoint_reachable,
      next_steps: (
        if ($issues | length) > 0 then
          ["Fix the issues listed above, then re-run: setup.sh check"]
        elif $config_valid then
          ["Config exists. Run: setup.sh verify to test it"]
        else
          ["Ready to configure. Agent needs: payment_manager_arn, payment_instrument_id, payment_session_id, user_id",
           "Run: setup.sh config --region REGION --payment-manager-arn ARN --payment-instrument-id ID --payment-session-id ID --user-id USER"]
        end
      )
    }'

  if [[ ${#issues[@]} -gt 0 ]]; then
    exit 2
  fi
}

# --- config: write config from flags ---
cmd_config() {
  local region="" pm_arn="" instrument_id="" session_id="" user_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)                 region="$2"; shift 2 ;;
      --payment-manager-arn)    pm_arn="$2"; shift 2 ;;
      --payment-instrument-id)  instrument_id="$2"; shift 2 ;;
      --payment-session-id)     session_id="$2"; shift 2 ;;
      --user-id)                user_id="$2"; shift 2 ;;
      --force)                  shift ;;  # allow overwrite
      *) json_error "Unknown flag: $1" ;;
    esac
  done

  # Validate required fields
  local missing=()
  [[ -z "$region" ]] && missing+=("--region")
  [[ -z "$pm_arn" ]] && missing+=("--payment-manager-arn")
  [[ -z "$instrument_id" ]] && missing+=("--payment-instrument-id")
  [[ -z "$session_id" ]] && missing+=("--payment-session-id")
  [[ -z "$user_id" ]] && missing+=("--user-id")

  if [[ ${#missing[@]} -gt 0 ]]; then
    local missing_json
    missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
    jq -n --arg status "error" --argjson missing "$missing_json" \
      '{status: $status, message: "Missing required flags", missing: $missing}'
    exit 1
  fi

  # Write config
  mkdir -p "$CONFIG_DIR"

  jq -n \
    --arg region "$region" \
    --arg pmArn "$pm_arn" \
    --arg instrumentId "$instrument_id" \
    --arg sessionId "$session_id" \
    --arg userId "$user_id" \
    '{
      region: $region,
      payment_manager_arn: $pmArn,
      payment_instrument_id: $instrumentId,
      payment_session_id: $sessionId,
      user_id: $userId
    }' > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"

  jq -n \
    --arg status "ok" \
    --arg path "$CONFIG_FILE" \
    --arg region "$region" \
    --arg pm_arn "$pm_arn" \
    --arg instrument_id "$instrument_id" \
    --arg session_id "$session_id" \
    --arg user_id "$user_id" \
    '{
      status: $status,
      message: "Config written successfully",
      config_path: $path,
      config: {
        region: $region,
        payment_manager_arn: $pm_arn,
        payment_instrument_id: $instrument_id,
        payment_session_id: $session_id,
        user_id: $user_id
      },
      next_steps: ["Run: setup.sh verify to confirm payments work",
                   "Or: x402-fetch.sh --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize"]
    }'
}

# --- verify: test that config + credentials actually work ---
cmd_verify() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    json_error "No config at $CONFIG_FILE — run setup.sh config first"
  fi

  local region instrument_id
  region=$(jq -r '.region // "us-east-1"' "$CONFIG_FILE")
  instrument_id=$(jq -r '.payment_instrument_id' "$CONFIG_FILE")

  # Test 1: AWS credentials
  local identity
  identity=$(aws sts get-caller-identity 2>/dev/null || echo "")
  if [[ -z "$identity" ]]; then
    json_error "AWS credentials invalid or expired"
  fi

  # Test 2: Can we reach AgentCore?
  local endpoint="https://bedrock-agentcore.${region}.amazonaws.com"
  local test_code
  test_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$endpoint" 2>/dev/null || echo "000")
  if [[ "$test_code" == "000" ]]; then
    json_error "Cannot reach AgentCore endpoint: $endpoint"
  fi

  # Test 3: Dry-run against a test URL
  local script_dir
  script_dir="$(cd "$(dirname "$0")/.." && pwd)"
  local fetch_script="${script_dir}/x402-fetch.sh"

  if [[ -x "$fetch_script" ]]; then
    local dry_run_output
    dry_run_output=$("$fetch_script" --dry-run "https://d2ibe85pfj1pv3.cloudfront.net/monetize" 2>/dev/null) || true

    if echo "$dry_run_output" | jq -e '.network' >/dev/null 2>&1; then
      jq -n \
        --arg status "ok" \
        --argjson challenge "$dry_run_output" \
        '{
          status: $status,
          message: "Verification passed — ready to pay",
          checks: {
            aws_credentials: "✓",
            agentcore_endpoint: "✓",
            test_endpoint_probe: "✓"
          },
          test_challenge: $challenge,
          next_steps: ["Everything works. Use x402-fetch.sh <url> to pay for content."]
        }'
    else
      jq -n \
        --arg status "partial" \
        '{
          status: $status,
          message: "AWS OK but test endpoint probe failed (may be down)",
          checks: {
            aws_credentials: "✓",
            agentcore_endpoint: "✓",
            test_endpoint_probe: "✗"
          },
          next_steps: ["Try: x402-fetch.sh --dry-run <your-target-url>"]
        }'
    fi
  else
    jq -n \
      --arg status "ok" \
      '{
        status: $status,
        message: "AWS credentials and endpoint OK",
        checks: {
          aws_credentials: "✓",
          agentcore_endpoint: "✓"
        },
        next_steps: ["Try: x402-fetch.sh --dry-run https://d2ibe85pfj1pv3.cloudfront.net/monetize"]
      }'
  fi
}

# --- show: dump current config as JSON ---
cmd_show() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    jq -n --arg status "error" --arg path "$CONFIG_FILE" \
      '{status: $status, message: "No config file found", config_path: $path}'
    exit 1
  fi
  jq -n --arg path "$CONFIG_FILE" --slurpfile config "$CONFIG_FILE" \
    '{status: "ok", config_path: $path, config: $config[0]}'
}

# --- usage ---
cmd_usage() {
  cat <<EOF
{
  "usage": "setup.sh <command> [flags]",
  "commands": {
    "check": "Check prerequisites, AWS creds, existing config. No flags needed.",
    "config": "Write config. Flags: --region, --payment-manager-arn, --payment-instrument-id, --payment-session-id, --user-id",
    "verify": "Verify config works (probes test endpoint).",
    "show": "Dump current config as JSON."
  },
  "examples": [
    "setup.sh check",
    "setup.sh config --region us-east-1 --payment-manager-arn arn:... --payment-instrument-id payment-instrument-XXX --payment-session-id payment-session-XXX --user-id myuser",
    "setup.sh verify",
    "setup.sh show"
  ],
  "notes": [
    "All output is JSON — designed for AI agent consumption.",
    "Exit 0=success, 1=error, 2=missing prerequisites.",
    "Config written to ~/.x402/config.json (0600 permissions)."
  ]
}
EOF
}

# --- Dispatch ---
case "${1:-}" in
  check)   shift; cmd_check "$@" ;;
  config)  shift; cmd_config "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  show)    cmd_show ;;
  *)       cmd_usage ;;
esac
