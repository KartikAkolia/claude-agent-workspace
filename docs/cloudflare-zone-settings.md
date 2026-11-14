# Cloudflare Zone Settings — kartikpassbolt.org

## Overview

Single Cloudflare zone, `kartikpassbolt.org` (Free Website plan, zone ID
`b1dcda9f5e18118679c33fde89472708`, account `Neerajakolia006@gmail.com's
Account`). Hosts `loopwire.kartikpassbolt.org` (the `personal-website`
Astro/Workers site) plus DNS records for other homelab services on the
same domain: `search` (SearXNG), `trilium` and `vault` (Vaultwarden, see
`vaultwarden-pi-setup.md`). The `adguardhome` record was removed by
2026-11-13 (see the DNS record note below). Since 2026-11-13, `trilium`
and `vault` reach the Pi through a Cloudflare Tunnel (see below).

2026-08-26: full free-plan settings review and hardening pass done via
the Cloudflare API MCP connector (`cloudflare-api` plugin), read-only
audit first, changes applied only after explicit approval.

## Changes made (2026-08-26)

- **WAF Managed Free Ruleset deployed.** The ruleset existed in the
  account's catalog but had no entrypoint deployed on this zone's
  `http_request_firewall_managed` phase — confirmed via a direct API
  check (`GET .../rulesets/phases/http_request_firewall_managed/entrypoint`
  returned "could not find entrypoint ruleset"), not assumed. Fixed by
  `PUT`-ing an entrypoint with an `execute` rule referencing ruleset ID
  `77454fe2d30c4220b5701f6fdfb893ba`. This was the single biggest gap
  found: the free-tier managed WAF rules were not actually running.
- **Smart Tiered Cache**: enabled (`tiered_cache_smart_topology_enable`
  → `on`). Free-tier eligible, reduces origin load and improves cache
  hit ratio.
- **Early Hints**: enabled (`early_hints` → `on`). Free, 103-response
  perf improvement, no known downside for this stack.
- **DNSSEC**: enabled on the Cloudflare side (`PATCH
  /zones/{id}/dnssec` → `status: active`, which generated the DS
  record below). Registrar-side DS record added at Namecheap by
  Kartik; propagation to public resolvers polled after.

## Attempted, did not take effect

- **Auto Minify (CSS/HTML/JS)**: `PATCH /zones/{id}/settings/minify`
  returned `200`/`success: true` both times it was tried, but the
  returned value stayed `{css: off, html: off, js: off}` and
  `modified_on` stayed `null` — the change never actually applied.
  Likely a feature Cloudflare has quietly retired on the backend while
  leaving the setting visible in the dashboard/API. Not pursued
  further; minification for this site should come from the Astro/Vite
  build itself rather than this toggle.

## Deliberately left for Kartik to decide/do

- **Account 2FA**: still disabled (`enforce_twofactor: false`, this is
  a Super Administrator account). Dashboard-only action (My Profile →
  Authentication), can't be done via API.
- **Hotlink Protection**: still off. Likely safe to enable — it only
  blocks direct hotlinking of image/media files by Referer header, not
  HTML/iframe embedding — but `personal-website`'s `/embed/widget/`
  route exists specifically to be iframe-embedded on other sites, so
  this was left for explicit confirmation rather than assumed safe.
- **HSTS preload**: still off. Submission to browser HSTS preload
  lists is effectively irreversible for a long time once accepted, so
  left as an explicit opt-in rather than enabled by default.

## DNS record note (not a "setting", but relevant)

`adguardhome.kartikpassbolt.org` is DNS-only (grey-cloud, unproxied)
and resolves to the same origin IP as the proxied `search`/`trilium`/
`vault` records. That means the origin IP is discoverable from public
DNS regardless of any WAF/security-level settings on the proxied
records — those only protect traffic that actually goes through
Cloudflare's proxy. Flagged for awareness; no DNS records were changed.

2026-10-31: AdGuardHome was removed from the Pi, so nothing listens behind
`adguardhome.kartikpassbolt.org` any more. The record itself was gone by
2026-11-13 (`dig` returned no A record; open item 44 in `docs/handoff.md`).

## Cloudflare Tunnel (2026-11-13)

`vault` and `trilium` no longer reach the Pi through router port-forwards.
A remotely managed tunnel, `kartikpassbolt`
(`8ad0ab1c-1ac8-4543-9171-8ea59ac3075f`), runs as the `cloudflared`
systemd service on the Pi. It was installed from `pkg.cloudflare.com` and
runs with the token from the dashboard. Both DNS records are type `Tunnel`
(a proxied CNAME to `<id>.cfargotunnel.com`), so they no longer point at
the home IP.

| Route | Service | Origin Server Name |
|---|---|---|
| `trilium.kartikpassbolt.org` | `https://localhost:443` | `trilium.kartikpassbolt.org` |
| `vault.kartikpassbolt.org` | `https://localhost:443` | `vault.kartikpassbolt.org` |

Both routes go to Nginx Proxy Manager, which still does TLS and routing.
Setting the Origin Server Name keeps certificate checks on between
`cloudflared` and NPM. Verified on 2026-11-13: NPM logs tunnel requests
from `10.0.2.2` (the host as seen from rootless Docker), and
`/.well-known/acme-challenge/` is reachable over plain HTTP through the
tunnel, so the `webroot` certificate renewals don't need port 80
forwarded. The router's TCP 80/443 forwards to the Pi were then removed.

Later the same day, both certificates moved to the DNS-01 challenge
(`npm-20` for `vault` and `npm-21` for `trilium`), so renewals no longer
send any HTTP request to the Pi. The reason was Bot Fight Mode: WAF skip
rules can't exempt traffic from it, so it could challenge Let's Encrypt's
HTTP-01 requests. NPM uses a Cloudflare API token from the Edit zone DNS
template, limited to this zone. That permission can change every DNS
record in the zone, so treat the token like a password: rotate it in the
dashboard if the Pi or an NPM backup leaks. NPM writes it to a credentials
file only while certbot runs, so test renewals with NPM's **Renew Now**,
not `certbot renew --dry-run`.

### How a request reaches the Pi

```text
Browser ──HTTPS──▶ Cloudflare edge ══ tunnel ══▶ cloudflared (Pi)
                                                   │ https://localhost:443
                                                   ▼
                                         Nginx Proxy Manager
                                                   │
                                         ┌─────────┴─────────┐
                                     vaultwarden          trilium
```

The direction of the connection is the key change. Before, Cloudflare
connected in to the home IP through router port-forwards, and anyone who
knew that IP could skip Cloudflare and connect the same way. Now
`cloudflared` starts on boot and opens four outbound QUIC connections to
nearby Cloudflare data centres (London, seen as `lhr*` in its log), then
keeps them open. When a browser asks for `vault` or `trilium`, Cloudflare
applies the zone's WAF and DDoS protection as before, then sends the
request back down one of those connections. `cloudflared` passes it to
NPM on `localhost:443` and checks NPM's certificate against the
hostname. NPM picks the site by hostname and passes the request to
Vaultwarden or Trilium as before.

Because the connection starts inside the home network, the router
forwards nothing for the websites, and public DNS no longer contains the
home IP for these two names. There is nothing at home for an outsider to
connect to.

### Day to day

- **Adding an app:** add another published application route to the
  tunnel in the dashboard (Networking → Tunnels → `kartikpassbolt` →
  Routes). The route config lives in Cloudflare, not in a file on the Pi,
  and needs no router or DNS work.
- **If both sites show a Cloudflare `1033`/`530` error page:**
  `cloudflared` is down or disconnected. Check `systemctl status
  cloudflared` on the Pi, then try `sudo systemctl restart cloudflared`.
  It reconnects by itself after internet drops.
- **Updates:** `cloudflared` comes from Cloudflare's apt repo, so normal
  `apt` upgrades keep it current.
- **The token:** whoever has it can run this tunnel. It's stored on the
  Pi by `cloudflared service install`. If it might have leaked, rotate it
  in the dashboard and reinstall the service with the new one.
- **From home:** nothing changes. LAN devices still reach the sites
  through Cloudflare, and NPM admin is at `http://192.168.0.166:81`.

The Pi's `ufw` was turned on the same day: it allows TCP 22, 80, 443 and
81 and UDP 5353 from `192.168.0.0/24` only. `cloudflared` reaches NPM over
loopback, which `ufw` always allows, so the tunnel doesn't need a rule.

Rollback: run `sudo ufw disable` on the Pi (or add a public allow for TCP
80 and 443), re-add the router forwards for TCP 80 and 443 to
`192.168.0.166`, then replace each `Tunnel` record with a proxied `A`
record to the home IP. Remaining checks are open item 55 in
`docs/handoff.md`.

## DNSSEC DS record (for reference)

```text
kartikpassbolt.org. 3600 IN DS 2371 13 2 25E366A3280339758EB5C8F73CA845C53DEC374CD86E32AC9A02224A65569357
```

- Key Tag: `2371`
- Algorithm: `13` (ECDSAP256SHA256)
- Digest Type: `2` (SHA256)
- Digest: `25E366A3280339758EB5C8F73CA845C53DEC374CD86E32AC9A02224A65569357`

Added at Namecheap (Domain → Advanced DNS → DNSSEC) 2026-08-26.
Confirmed propagated: `GET /zones/{id}/dnssec` → `status: active`.

## Root + www redirect (2026-08-26)

Cloudflare's own zone-health checks flagged `kartikpassbolt.org` and
`www.kartikpassbolt.org` as unreachable — neither had an A/AAAA/CNAME
record, so a visitor hitting either directly got a connection error.
Kartik confirmed he wants both to redirect to the real site,
`loopwire.kartikpassbolt.org` (see `personal-website/ROADMAP.md` Phase
4), rather than actually serving content at the bare root.

Implemented the standard Cloudflare pattern for this:

- Two proxied (orange-cloud) `A` records added, both pointing at the
  documentation/reserved dummy IP `192.0.2.1` — never actually
  contacted, since Cloudflare intercepts the request before it would
  reach an origin, as long as the record is proxied and a redirect
  rule matches:
   - `kartikpassbolt.org` → `192.0.2.1`
   - `www.kartikpassbolt.org` → `192.0.2.1`
- One Redirect Rule (Single Redirect, free-plan feature) deployed to
  the `http_request_dynamic_redirect` phase entrypoint: matches
  `http.host eq "kartikpassbolt.org"` or `http.host eq
  "www.kartikpassbolt.org"`, `301`-redirects to
  `https://loopwire.kartikpassbolt.org` with the original path and
  query string preserved (`concat("https://loopwire.kartikpassbolt.org",
  http.request.uri.path)`, `preserve_query_string: true`).

Verified live via `curl -o /dev/null -w '%{http_code} -> %{redirect_url}'`:
`kartikpassbolt.org/` and `kartikpassbolt.org/dashboard/` both `301` to
the matching `loopwire.kartikpassbolt.org` path; `www.kartikpassbolt.org/`
same. One false alarm along the way: Kartik's own browser initially
showed "server IP address could not be found" for `www` — that was his
machine's local DNS cache, not a real propagation issue (public
resolvers Cloudflare/Google/Quad9 all resolved it correctly at the
time); resolved by clearing the browser cache.
