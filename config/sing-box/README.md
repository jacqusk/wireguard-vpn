# sing-box Configs

This directory contains tracked sing-box templates.

## Available Templates

- [wg-residential-udp-relay.json.template](wg-residential-udp-relay.json.template) — TPROXY UDP relay config for residential SOCKS5 proxies

## Usage

1. Copy the template to `/etc/sing-box/wg-residential-udp-relay.json` on EC2.
2. Replace placeholders:
   - `UPSTREAM_SOCKS5_HOST` — upstream proxy hostname or IP
   - `UPSTREAM_USERNAME` / `UPSTREAM_PASSWORD` — credentials (or remove if not required)
3. Adjust `listen_port` if using a non-default `RESIDENTIAL_PROXY_UDP_LOCAL_PORT`.

Runtime configs should not be committed. The live path used by the project is:

- `/etc/sing-box/wg-residential-udp-relay.json`