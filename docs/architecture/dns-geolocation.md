# DNS Geolocation and DoH Considerations

## Why We Use Provider's DNS (RESIDENTIAL_DNS_UPSTREAM_IP)

When using a residential proxy for geolocation purposes, **DNS must match the proxy's location**. 
DNS leak tests check which DNS servers resolve your queries - if they're in a different country 
than your apparent IP, it reveals your actual location.

## Why DoH (DNS-over-HTTPS) Doesn't Work for Geolocation

We evaluated using dnscrypt-proxy with DoH providers (Cloudflare, Google) to eliminate 
the hardcoded DNS IP dependency. **This approach fails for geolocation purposes:**

### The Problem

1. **Anycast Routing**: Cloudflare/Google DoH uses anycast - requests are routed to the 
   nearest edge server based on network topology, not IP geolocation.

2. **ASN-Based Routing**: Our residential proxy IP (e.g., 109.72.116.199) may geolocate 
   to Ireland, but the ASN is AS3320 (Deutsche Telekom AG). DoH providers see the 
   Deutsche Telekom network and route to German edge servers.

3. **Result**: DNS leak tests show Frankfurt DNS servers, revealing the proxy uses 
   German infrastructure even though the IP geolocates to Ireland.

### Technical Details

```
DoH Request Flow:
Client → WireGuard → dnscrypt-proxy → HTTPS → redsocks → proxy (AS3320)
                                                           ↓
                                              Cloudflare sees AS3320
                                                           ↓
                                              Routes to Frankfurt edge
                                                           ↓
                                              DNS leak shows German servers
```

### The Solution

Use the proxy provider's DNS server (RESIDENTIAL_DNS_UPSTREAM_IP):
- Located in the same region as the proxy endpoint
- Ensures DNS servers match proxy geolocation
- No anycast routing issues

```
Current DNS Flow:
Client → WireGuard → iptables REDIRECT → systemd-resolved (10.44.0.1)
                                                ↓
                                        54.72.70.84 (Ireland)
                                                ↓
                                        DNS leak shows Irish servers
```

## Configuration

The DNS upstream is configured via `RESIDENTIAL_DNS_UPSTREAM_IP` environment variable:

```bash
RESIDENTIAL_DNS_UPSTREAM_IP="54.72.70.84"  # Proxy provider's Irish DNS
```

This is set in `/etc/default/wireguard-egress` and used by:
- `apply-vpn-firewall.sh` - allows OUTPUT to this IP on port 53
- `systemd-resolved` - uses this as upstream DNS server

## Future Considerations

If DoH is required for privacy/encryption while maintaining geolocation:
1. The proxy provider would need to offer a DoH endpoint in Ireland
2. Or use a DoH provider with Irish-specific endpoints (not anycast)
3. Or accept that DNS geolocation won't match IP geolocation
