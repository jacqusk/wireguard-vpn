# DNS Geolocation and DoH Considerations

## Why We Use Provider's DNS

When using a residential proxy for geolocation purposes, **DNS must match the proxy's location**. 
DNS leak tests check which DNS servers resolve your queries - if they're in a different country 
than your apparent IP, it reveals your actual location.

## Architecture: Client-Controlled DNS

DNS is configured **on the client** (in WireGuard profile). The server only forwards DNS traffic:

```
Client (DNS=54.72.70.84) → WireGuard → Server FORWARD → MASQUERADE → 54.72.70.84
```

**Client controls DNS behavior:**
| Client DNS Setting | Result |
|-------------------|--------|
| `DNS = 54.72.70.84` | Irish DNS (correct for Irish proxy) |
| `DNS = 8.8.8.8` | Google DNS (potential geo mismatch) |
| `DNS = 1.1.1.1` | Cloudflare DNS (potential geo mismatch) |
| No DNS setting | System default outside tunnel (leak!) |

**Recommended:** Set `DNS = 54.72.70.84` (or current provider's DNS from config).

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

## Configuration

The DNS upstream is configured via `RESIDENTIAL_DNS_UPSTREAM_IP` environment variable:

```bash
RESIDENTIAL_DNS_UPSTREAM_IP="54.72.70.84"  # Proxy provider's Irish DNS
```

This is used by:
- `apply-vpn-firewall.sh` - allows FORWARD to this IP on port 53, blocks other DNS
- `client_template_dns_line()` - sets DNS in WireGuard client profiles

## Future Considerations

If DoH is required for privacy/encryption while maintaining geolocation:
1. The proxy provider would need to offer a DoH endpoint in Ireland
2. Or use a DoH provider with Irish-specific endpoints (not anycast)
3. Or accept that DNS geolocation won't match IP geolocation
