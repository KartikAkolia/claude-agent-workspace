# Cloudflare Zone Settings — kartikpassbolt.org

## Overview

Single Cloudflare zone, `kartikpassbolt.org` (Free Website plan, zone ID
`b1dcda9f5e18118679c33fde89472708`, account `Neerajakolia006@gmail.com's
Account`). Hosts `loopwire.kartikpassbolt.org` (the `personal-website`
Astro/Workers site) plus DNS records for other homelab services on the
same domain: `search` (SearXNG), `trilium`, `vault` (Vaultwarden, see
`vaultwarden-pi-setup.md`), and `adguardhome`.

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

## DNSSEC DS record (for reference)

```text
kartikpassbolt.org. 3600 IN DS 2371 13 2 25E366A3280339758EB5C8F73CA845C53DEC374CD86E32AC9A02224A65569357
```

- Key Tag: `2371`
- Algorithm: `13` (ECDSAP256SHA256)
- Digest Type: `2` (SHA256)
- Digest: `25E366A3280339758EB5C8F73CA845C53DEC374CD86E32AC9A02224A65569357`

Added at Namecheap (Domain → Advanced DNS → DNSSEC) 2026-08-26.
Cloudflare-side status was still `pending` as of the last check before
propagation was confirmed — see git history/session notes for the
final confirmed-active timestamp if this doc wasn't updated after.
