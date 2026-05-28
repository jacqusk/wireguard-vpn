# Tests Layout

This repository separates future automated checks into:

- `tests/smoke/` for fast post-change validation,
- `tests/integration/` for broader environment-aware checks,
- `tests/fixtures/` for sample inputs and sanitized test data.

Current automated smoke entrypoint:

- `tests/smoke/validate-shell-scripts.sh` validates shell syntax for tracked repo scripts and runs `shellcheck` when available.
- `tests/smoke/validate-first-rollout-examples.sh` validates and renders a sanitized first-rollout configuration from the tracked example files.

The current authoritative manual plan remains in [../docs/testing/post-deployment-test-plan.md](../docs/testing/post-deployment-test-plan.md).