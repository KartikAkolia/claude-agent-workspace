# Vaultwarden on Raspberry Pi 5

## Overview

Self-hosted [Vaultwarden](https://github.com/dani-garcia/vaultwarden) (Bitwarden-compatible server), reachable at `https://vault.kartikpassbolt.org`.

- Host: Raspberry Pi 5, Raspberry Pi OS (forky/sid), aarch64. Local IP `192.168.0.166`.
- SSH: `ssh pi` (alias already configured on the Windows side, key-based, no password prompt).
- Reverse proxy: `nginx-proxy-manager` container on the same host handles TLS/routing to Vaultwarden and its other sibling containers (`searxng`, `trilium`, `watchtower`).
- Vaultwarden is its own Docker Compose project at `/home/pi/vaultwarden/docker-compose.yml` (project name `vaultwarden`, container name `vaultwarden`, data volume `vaultwarden_vaultwarden-data`).

## Current config (as of 2026-08-26)

Key environment variables set in `docker-compose.yml`:

- `DOMAIN=https://vault.kartikpassbolt.org`
- `SIGNUPS_ALLOWED=false` — self-registration is locked down. Deliberate; leaving this `true` is the most common misconfiguration on public Vaultwarden instances.
- `WEBSOCKET_ENABLED=true`
- `SMTP_HOST=smtp.gmail.com`, `SMTP_PORT=587`, `SMTP_SECURITY=starttls`, `SMTP_USERNAME`/`SMTP_FROM=neerajakolia006@gmail.com` — SMTP is fully configured and working, so admin invites send correctly.
- `ADMIN_TOKEN` — an **Argon2id PHC hash** (see below), not plaintext.

## Giving another user their own vault

Each user's personal vault is created automatically when their account is registered on the instance — there's no separate "create a vault" step. With `SIGNUPS_ALLOWED=false`, the only way in is an admin invite:

1. Log in at `https://vault.kartikpassbolt.org/admin` with the admin token (see below for what that means with a hashed token).
2. **Users → Invite User** → enter their email address.
3. They receive an email (sent from `neerajakolia006@gmail.com` via the configured SMTP) with an invite link, follow it, set their own master password. Vault exists as of that point.
4. Leave `SIGNUPS_ALLOWED=false` afterward.

If SMTP ever breaks, the admin panel's "Send Test Email" button is the fastest way to confirm before relying on the invite flow.

## Admin token: plaintext → Argon2 hash

The `ADMIN_TOKEN` started out as a plaintext random string, which Vaultwarden flags as insecure at container startup:

> You are using a plain text `ADMIN_TOKEN` which is insecure. Please generate a secure Argon2 PHC string...

Resolved by generating a new random secret and hashing it with the `argon2` CLI (already installed on this Pi) using the Bitwarden-preset parameters (`m=65540, t=3, p=4`, matching what `vaultwarden hash` itself would produce), then storing the resulting PHC string as `ADMIN_TOKEN` in `docker-compose.yml`.

**Important gotcha:** Docker Compose interpolates `$` in inline `environment:` values. An Argon2 PHC string is full of `$` delimiters (`$argon2id$v=19$m=...$salt$hash`), so every `$` in the hash must be doubled to `$$` in the compose file, or Compose will silently mangle the value on the next `up`.

**Login behavior changed:** with a hashed `ADMIN_TOKEN`, you no longer log in with the hash — you log in with the *original plaintext secret* that was hashed. That plaintext secret was written to `/home/pi/vaultwarden/.new_admin_token` on the Pi (chmod 600) so it could be retrieved once, since Claude Code's auto-mode classifier blocks printing token-shaped secrets into the chat transcript — it had to be read directly by Kartik via `ssh pi "cat /home/pi/vaultwarden/.new_admin_token"`.

**Resolved (2026-08-26):** Kartik chose to keep `.new_admin_token` on disk rather than delete it, and locked it down instead: `600` permissions (owner-only), dot-prefixed (hidden from plain `ls`), and now `chattr +i` (immutable — can't be modified or deleted, even by root, without first running `sudo chattr -i` on it). `chattr` requires root, and this Pi's `pi` user doesn't have passwordless `sudo`, so that step had to be run interactively by Kartik (`ssh -t pi "sudo chattr +i ..."`), not by Claude Code directly.

## Regenerating the admin token again in future

```bash
ssh pi 'bash -s' <<'REMOTE_SCRIPT'
set -e
cd /home/pi/vaultwarden

NEWTOKEN=$(openssl rand -base64 48)
SALT=$(openssl rand -base64 32)
HASH=$(printf '%s' "$NEWTOKEN" | argon2 "$SALT" -e -id -k 65540 -t 3 -p 4)

ESCAPED_HASH=${HASH//\$/\$\$}
sed -i "s|ADMIN_TOKEN:.*|ADMIN_TOKEN: \"$ESCAPED_HASH\"|" docker-compose.yml

echo "$NEWTOKEN" > .new_admin_token
chmod 600 .new_admin_token
REMOTE_SCRIPT

ssh pi "cd /home/pi/vaultwarden && docker compose up -d"
ssh pi "cat /home/pi/vaultwarden/.new_admin_token"   # retrieve, save it, then delete the file
```
