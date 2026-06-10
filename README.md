# 402skills

Payment skills for AI agents. Each skill under `skills/` handles a specific payment protocol.

## Available Skills

| Skill | Protocol | Dependencies |
|-------|----------|--------------|
| [x402-payments](skills/x402-payments/) | x402 (HTTP 402 + stablecoin) | bash, curl, jq, aws cli |

## Structure

```
skills/
└── x402-payments/      # x402 HTTP payment protocol
    ├── README.md       # Agent-friendly docs
    ├── SKILL.md        # OpenClaw skill trigger
    ├── x402-fetch.sh   # Main tool
    ├── x402-status.sh  # Status check
    ├── x402-renew.sh   # Session renewal
    └── scripts/        # Setup wizard
```

## Adding a new skill

Create a directory under `skills/` with at minimum:
- `README.md` — what it does, how to use it
- `SKILL.md` — when an agent should trigger it
- One or more executable scripts
