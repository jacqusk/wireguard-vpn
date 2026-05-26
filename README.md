# WireGuard VPN on AWS EC2

Professional repository layout for a WireGuard-based AWS EC2 VPN with:

- multi-peer support,
- strict fail-closed egress handling,
- optional residential proxy mode,
- optional UDP relay plumbing for SOCKS5 UDP ASSOCIATE,
- AWS tag-driven egress switching.

## Language

This repository uses a bilingual documentation model:

- root-level onboarding is kept broadly readable,
- most operational runbooks and deployment guides remain in Polish.

## Repository Layout

```text
.
|-- docs/
|   |-- architecture/
|   |-- deployment/
|   |-- guides/
|   |-- optional-features/
|   |-- runbooks/
|   `-- testing/
|-- scripts/
|   |-- aws/
|   |-- bootstrap/
|   |-- firewall/
|   |-- health/
|   `-- runtime/
|-- config/
|   |-- examples/
|   |-- sing-box/
|   |-- systemd/
|   `-- wireguard/
|-- tests/
|   |-- fixtures/
|   |-- integration/
|   `-- smoke/
|-- .github/workflows/
`-- generated/
```

## Main Entry Points

- Manual bootstrap: [scripts/bootstrap/bootstrap-wireguard-ec2.sh](scripts/bootstrap/bootstrap-wireguard-ec2.sh)
- EC2 user-data bootstrap: [scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh](scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh)
- Firewall policy: [scripts/firewall/apply-vpn-firewall.sh](scripts/firewall/apply-vpn-firewall.sh)
- Runtime helper: [scripts/runtime/wireguard-egress.sh](scripts/runtime/wireguard-egress.sh)

## Primary Docs

- Deployment checklist: [docs/deployment/aws-console-deployment-checklist.md](docs/deployment/aws-console-deployment-checklist.md)
- Architecture and plan: [docs/architecture/vpn-aws-wireguard-v1-plan.md](docs/architecture/vpn-aws-wireguard-v1-plan.md)
- Test plan: [docs/testing/post-deployment-test-plan.md](docs/testing/post-deployment-test-plan.md)
- Optional UDP relay: [docs/optional-features/socks5-udp-optional-setup.md](docs/optional-features/socks5-udp-optional-setup.md)

## Git Safety

Do not commit generated WireGuard client profiles, private keys, PSKs, `.env` files, or runtime relay configs.

- tracked examples and templates belong in `config/`
- generated outputs belong in `generated/`
- runtime secrets stay outside Git

See [docs/README.md](docs/README.md) for the documentation map.