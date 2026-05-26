# Health Scripts

This directory is reserved for future health and validation helpers, for example:

- status summaries,
- post-deploy smoke checks,
- readiness checks for egress mode and relay state.

Current helper:

- `validate-first-rollout-inputs.sh` - validates the filled preflight and first-rollout user-data values before deployment
- `render-first-rollout-user-data.sh` - renders a deployment-ready EC2 user-data script from validated first-rollout inputs