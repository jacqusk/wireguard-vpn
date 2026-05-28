# Tests Layout

This repository separates future automated checks into:

- `tests/smoke/` for fast post-change validation,
- `tests/integration/` for broader environment-aware checks,
- `tests/fixtures/` for sample inputs and sanitized test data.

Current automated smoke entrypoint:

- `tests/smoke/validate-shell-scripts.sh` validates shell syntax for tracked repo scripts and runs `shellcheck` when available.

The current authoritative manual plan remains in [../docs/testing/post-deployment-test-plan.md](../docs/testing/post-deployment-test-plan.md).