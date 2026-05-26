# Config Examples

Non-secret bootstrap examples and environment starters.

## Available Examples

- [wireguard-egress.env.example](wireguard-egress.env.example) — `/etc/default/wireguard-egress` template
- [wireguard-egress-aws-sync.env.example](wireguard-egress-aws-sync.env.example) — `/etc/default/wireguard-egress-aws-sync` template
- [peer-definitions.first-rollout.example.txt](peer-definitions.first-rollout.example.txt) — example `PEER_DEFINITIONS` for `phone-test-1` and `cloud-test-1`
- [user-data.first-rollout.example.env](user-data.first-rollout.example.env) — safe first-rollout values for `ec2-user-data-wireguard-bootstrap.sh`
- [deployment-preflight.first-rollout.example.env](deployment-preflight.first-rollout.example.env) — fill-in checklist of the AWS/GitHub/account decisions to confirm before real deployment

## Usage

Copy to the target path on EC2 and fill in real values. Remove `.example` suffix.

Do not store real secrets in this directory.