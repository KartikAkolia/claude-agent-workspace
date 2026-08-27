# CLIProxyAPI on dell-optiplex

## Overview

[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a Go proxy exposing OpenAI/Gemini/Claude/Codex/Grok-compatible API endpoints, backed by OAuth-linked CLI subscription accounts instead of pay-per-token API keys. Set up on the homelab host `dell-optiplex` (`192.168.0.222`) to give Claude Code (via Headroom) a stable upstream and, longer-term, a place to consolidate other provider accounts.

- Host: `dell-optiplex`, rootless Podman.
- Image: `docker.io/eceasy/cli-proxy-api:latest`.
- Project dir: `~/cli-proxy-api/` (`config.yaml`, `auths/`, `logs/`, `plugins/`).
- Listens on `127.0.0.1:8317` (API) plus the OAuth callback ports below — loopback-only, not reachable from the LAN.

## Config

`~/cli-proxy-api/config.yaml`:

```yaml
host: ""
port: 8317

tls:
  enable: false

remote-management:
  allow-remote: false
  disable-control-panel: false

auth-dir: "/root/.cli-proxy-api"   # inside the container; bind-mounted from ~/cli-proxy-api/auths

api-keys:
  - "7781f8658d6989701e8b5287ee3949afe8a312311ec8e438"

debug: false
logging-to-file: true
logs-max-total-size-mb: 200
usage-statistics-enabled: true
proxy-url: ""
request-retry: 3
ws-auth: true
```

`remote-management.allow-remote: false` and TLS disabled are both deliberate — everything is bound to `127.0.0.1` (see the Quadlet unit below), so there's no external exposure to protect against yet. Revisit both if the LAN-exposure item below is ever acted on.

## Linking a provider account: Claude Code

Kartik's access to `dell-optiplex` is SSH console only — no browser on the host. CLIProxyAPI's OAuth flows are all browser-redirect based, so linking an account needs an SSH local port-forward to bridge the host's OAuth callback listener out to a browser on the client machine.

1. Run the login flow on the host, e.g.:

   ```bash
   podman run --rm -it \
     --entrypoint ./CLIProxyAPI \
     -v ~/cli-proxy-api/config.yaml:/CLIProxyAPI/config.yaml \
     -v ~/cli-proxy-api/auths:/root/.cli-proxy-api \
     -p 127.0.0.1:54545:54545 \
     docker.io/eceasy/cli-proxy-api:latest --claude-login
   ```

   This prints an OAuth URL and starts listening on `54545` for the callback.

2. **CLIProxyAPI prints its own suggested SSH tunnel command — don't trust it blindly.** It's boilerplate and printed a placeholder host/user (`ssh -L 54545:127.0.0.1:54545 root@86.2.4.121 -p 22`) that had nothing to do with this host. The real command, for this setup, is:

   ```bash
   ssh -L 54545:127.0.0.1:54545 kartik@192.168.0.222
   ```

   Run that from the client machine (Kartik's Windows console), *in addition to* the normal SSH session already open to the host — it just needs the port forward, doesn't have to be the working shell.

3. Open the printed OAuth URL in a browser on the client machine, complete the Claude login. The callback comes back through the tunnel to the listener on the host.

4. On success, CLIProxyAPI writes the credential to `~/cli-proxy-api/auths/claude-<email>.json` inside the container's mounted `auth-dir`. Tighten permissions afterward:

   ```bash
   chmod 600 ~/cli-proxy-api/auths/*.json
   ```

Currently linked: **Claude Code** (`claude-neerajakolia006@gmail.com.json`). Not yet linked: Codex, Gemini/Antigravity, Grok/xAI, Kimi — CLIProxyAPI supports all of these the same way, just with a different `--*-login` flag; add them if a need comes up.

## Running it (reboot-persistent)

Originally started as an ad-hoc `podman run`, then converted to a Podman Quadlet unit so it survives logout and reboot without a hand-run command. Quadlet units live under `~/.config/containers/systemd/` and get turned into real systemd `--user` units automatically by `systemctl --user daemon-reload` — no separate Podman service manager to configure.

`~/.config/containers/systemd/cli-proxy-api.container`:

```ini
[Unit]
Description=CLIProxyAPI - OpenAI/Gemini/Claude/Codex compatible proxy
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/eceasy/cli-proxy-api:latest
ContainerName=cli-proxy-api
PublishPort=127.0.0.1:8317:8317
PublishPort=127.0.0.1:8085:8085
PublishPort=127.0.0.1:1455:1455
PublishPort=127.0.0.1:54545:54545
PublishPort=127.0.0.1:51121:51121
PublishPort=127.0.0.1:11451:11451
Volume=%h/cli-proxy-api/config.yaml:/CLIProxyAPI/config.yaml
Volume=%h/cli-proxy-api/auths:/root/.cli-proxy-api
Volume=%h/cli-proxy-api/logs:/CLIProxyAPI/logs
Volume=%h/cli-proxy-api/plugins:/CLIProxyAPI/plugins
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=60

[Install]
WantedBy=default.target
```

Load and start:

```bash
systemctl --user daemon-reload
systemctl --user start cli-proxy-api.service
```

**`systemctl --user enable` fails on this unit** ("Unit is transient or generated") — that's expected for Quadlet-generated units, not an error to chase. Auto-start at login is handled by the `[Install] WantedBy=default.target` line in the `.container` file itself instead; confirmed present via `systemctl --user list-dependencies default.target`.

**Full reboot survival** (service starts even with nobody logged in at the console) additionally needs `loginctl show-user kartik` to report `Linger=yes` — confirmed already set on this host, so no further action was needed here. If it's ever off (`loginctl enable-linger kartik`, needs root), it must be run by Kartik directly; Claude Code sessions on this host don't have passwordless sudo.

Port map (all loopback-only):

| Port | Purpose |
|---|---|
| 8317 | Main API (OpenAI/Gemini/Claude/Codex-compatible endpoints) |
| 8085, 1455, 54545, 51121, 11451 | OAuth callback listeners for the various provider login flows |

## Chaining Headroom through it

Headroom (the local context-optimization proxy Claude Code talks to) was reconfigured to send its own upstream Anthropic calls through CLIProxyAPI instead of directly to `api.anthropic.com`, so Claude Code gets CLIProxyAPI's OAuth-account-backed reliability underneath Headroom's compression. Full detail, including a scope bug hit along the way, is in the handoff log — see `docs/handoff.md`'s 2026-08-27 "CLIProxyAPI set up... Headroom chained through it" section for the blow-by-blow. Summary:

- New persistent deployment: `headroom-default.service` (systemd `--user`, port 8787), independent of any interactive session.
- Its upstream is overridden via `ANTHROPIC_TARGET_API_URL=http://127.0.0.1:8317` and `ANTHROPIC_TARGET_API_HEADERS={"x-api-key":"<CLIProxyAPI's key>"}`.
- Claude Code's `~/.claude/settings.json` points at Headroom (`ANTHROPIC_BASE_URL=http://127.0.0.1:8787`), which now points at CLIProxyAPI, which round-robins across whatever OAuth accounts are linked.
- Side effect: Claude Code's Remote Control (`/rc`) is disabled whenever `ANTHROPIC_BASE_URL` is overridden like this — `headroom doctor` surfaces this as a warning, expected and not a bug.

## Verifying it's healthy

```bash
systemctl --user status cli-proxy-api.service headroom-default.service --no-pager
curl -s http://127.0.0.1:8787/readyz   # Headroom's own health check, includes an "upstream" probe of CLIProxyAPI
~/.local/bin/headroom doctor --port 8787
```

`headroom doctor` should report `claude ✓ pass`, `shell env ✓ pass`, and `deployments ✓ pass`.

## Known gaps / open items

- Only Claude Code is linked. Codex/Gemini/Grok/Kimi are supported by CLIProxyAPI but not set up — no need surfaced yet.
- Everything is loopback-only (`127.0.0.1`). Widening to the LAN would need an `nftables` firewall change on `dell-optiplex`, which needs Kartik's own sudo — not requested yet.
- `remote-management.allow-remote` and TLS are both off, matching the loopback-only exposure. Revisit together if LAN exposure is ever turned on — running a real control-panel/API port on the LAN without TLS or remote-management auth would be a real gap, not a style choice.
