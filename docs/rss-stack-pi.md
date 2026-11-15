# RSS stack on the Raspberry Pi 5

`scripts/rss-stack.sh` installs and runs a self-hosted RSS reader with Docker Compose: FreshRSS as the reader, RSS-Bridge for sites without a feed, and an optional `cloudflared` container for a Cloudflare Tunnel. It targets Debian, Ubuntu and Raspberry Pi OS on amd64 or arm64. This doc records how it is installed on the Pi 5 (`ssh pi`, `192.168.0.166`, Debian forky/sid, arm64), how the script fits that host, and what is still open. The Pi itself is described in `docs/raspberry-pi-host-setup.md` and `docs/vaultwarden-pi-setup.md`.

## Current state (verified 2026-11-15)

| Item | State |
|---|---|
| Install | `/opt/rss-stack` (`.env`, `compose.yaml`, `data/`, `backups/`, the installed `rss-stack.sh`) |
| FreshRSS | `freshrss/freshrss:latest`, version 1.30.4, arm64, container `freshrss` |
| RSS-Bridge | `rssbridge/rss-bridge:latest` (image built 2026-11-15), arm64, container `rssbridge`, internal only |
| Docker | the Pi's rootless daemon (user `pi`), not the system one |
| Access | LAN only: `http://192.168.0.166:8080`. No tunnel yet |
| Firewall | `ufw` rule "FreshRSS from LAN": 8080/tcp from `192.168.0.0/24` |
| Backups | `/etc/cron.d/rss-stack`, Sundays at 03:30, newest 7 kept in `/opt/rss-stack/backups` |
| Updates | manual only. Every container carries `com.centurylinklabs.watchtower.enable=false`, so the Pi's Watchtower skips them |

Credentials are not kept in this repo. `sudo /opt/rss-stack/rss-stack.sh credentials` prints the admin and Google Reader API passwords from `/opt/rss-stack/.env` (mode 600).

Checked on 2026-11-15: from the CachyOS laptop, `http://192.168.0.166:8080/` returns FreshRSS's login redirect. Inside the container, `www-data` can write `data/` and read `extensions/`, and `cli/reconfigure.php` succeeds. Both containers report arm64 images. The system Docker units (`docker.service`, `docker.socket`, `containerd.service`) are inactive and disabled again.

## Commands

Run as root. On this Pi, `sudo` already carries `DOCKER_HOST` (see below).

```bash
sudo /opt/rss-stack/rss-stack.sh install [--domain D] [--tunnel-token T] [--tz Z] [--user U] [--port P] [--dir DIR]
sudo /opt/rss-stack/rss-stack.sh update      # backs up, re-applies settings, pulls newer images
sudo /opt/rss-stack/rss-stack.sh backup      # tar.gz of .env, compose.yaml and data/, keeps the newest 7
sudo /opt/rss-stack/rss-stack.sh status      # containers, image architecture, HTTP check
sudo /opt/rss-stack/rss-stack.sh credentials # logins, API URL, internal URLs
```

After the first install, change settings with `update` rather than `install`: both re-apply settings and pull images, but only `update` takes a backup first. Settings come from the flag or environment variable, then the saved `.env`, then the default, and passwords are generated once and kept. `--dir` has to be repeated on every command if it isn't the default. `DRY_RUN=1` works with `install` only and writes the config files without touching apt or Docker; it doesn't need root, so `DRY_RUN=1 ./rss-stack.sh install --dir "$HOME/rss-dry"` is a safe preview.

## How the script fits this Pi

**Rootless Docker.** Everything on this Pi runs under rootless Docker as `pi`; the system daemon was disabled on 2026-11-13 (see `docs/handoff.md`). `/etc/environment` sets `DOCKER_HOST=unix:///run/user/1000/docker.sock`, and both `sudo` and cron read it through `pam_env` (`/etc/pam.d/cron` includes `pam_env.so`). The script saves the value as `STACK_DOCKER_HOST` in `.env` and exports it on every run, so cron, `update` and `status` reach the daemon the stack was installed on even without that environment. When `DOCKER_HOST` is set and Docker is already installed, the script leaves the system Docker service alone. Installing Docker from scratch through get.docker.com would still enable it. `DOCKER_HOST` must be a local `unix:///` socket, because the bind mounts are local paths.

**Ownership.** `/opt/rss-stack` and `data/` stay root-owned (mode 701: traverse only), because root's cron runs the installed script from there. The two bind-mount folders, `data/freshrss` and `data/extensions`, belong to the daemon's user: the owner of the `DOCKER_HOST` socket, here `pi:pi`. FreshRSS's entrypoint then regroups them to its own `www-data`, which shows on the host as gid 100032 (container gid 33 under the `pi` subgid range). One side effect: FreshRSS extensions, such as Image Proxy, can be installed as `pi` without `sudo` by cloning them into `/opt/rss-stack/data/extensions`, followed by `docker restart freshrss`.

**Firewall.** Rootless Docker publishes ports through `rootlesskit`, an ordinary userspace listener, so `ufw` filters them (rootful Docker would bypass `ufw`). That is why the "FreshRSS from LAN" rule was needed.

**Docker packages.** Docker 29.9.3 and Compose v5.7.1 come from Docker's trixie repo. `download.docker.com` has no forky suite (404 on 2026-11-15), so a fresh forky host couldn't get Docker through the script's get.docker.com step; here that step is skipped because Docker is already installed.

## Design choices

**No Full-Text RSS.** The original plan included FiveFilters Full-Text RSS. Its only free image, `heussd/fivefilters-full-text-rss`, was archived on 2026-11-07; it runs end-of-life PHP 5, and its README warns of actively exploited remote-code-execution bugs and says to migrate away. FiveFilters publishes no official image. Kartik chose to drop it. For summary-only feeds, use FreshRSS's per-feed setting under **Advanced**: "Article CSS selector on original website".

**`INTERNAL_HOST_ALLOWLIST`.** FreshRSS 1.30.0 added an SSRF guard that refuses feeds on private networks, which includes the Docker network RSS-Bridge sits on. The compose file sets `INTERNAL_HOST_ALLOWLIST: "rssbridge:80"`. When that variable is set it replaces the allowlist under *System configuration* entirely, so another internal source (RSSHub, say) has to be added to the compose heredoc in `scripts/rss-stack.sh`, not in the web UI.

**`TRUSTED_PROXY` left unset.** The image's Apache config already trusts `X-Forwarded-For` from the private ranges, which covers `cloudflared` on the Docker network. Setting the variable would only widen which IPs FreshRSS trusts for `Remote-User` headers.

**Manual updates.** The Watchtower label keeps updates manual, so FreshRSS's database migrations only happen through `update`, after its backup.

## Adding the tunnel (not done yet)

1. Create a new Cloudflare Tunnel token for RSS. Don't reuse the host tunnel `kartikpassbolt` (see `docs/cloudflare-zone-settings.md`): a second connector with the same token would get the same ingress rules, and the container can't reach the host's `localhost` services, so some Vaultwarden and Trilium requests would fail.
2. Run `sudo /opt/rss-stack/rss-stack.sh update --domain rss.<domain> --tunnel-token '<token>'`. It backs up, binds FreshRSS to `127.0.0.1` only, starts the `cloudflared` container and switches the base URL to `https://rss.<domain>`.
3. In Cloudflare, point the tunnel's public hostname at `http://freshrss:80`. Add Access with an email-only login policy, plus a Bypass policy for `/api/*` so phone apps can sync over the Google Reader API, which still needs the API password.
4. Remove the LAN rule: `sudo ufw delete allow from 192.168.0.0/24 to any port 8080 proto tcp`.

One unverified concern from the review: Cloudflare normalises incoming URLs but leaves `%2F` encoded, and FreshRSS's Apache config decodes encoded slashes. A request like `/api/..%2Fi/` might therefore match the `/api/*` Bypass and reach the web UI without the Access login. FreshRSS's own login would still apply. A WAF custom rule that blocks paths containing `..%2f` or `%2f..` would close it if it turns out to be real.

## Known limitations

- A saved value (domain, tunnel token, `STACK_DOCKER_HOST`) can't be cleared with a flag or an empty variable; edit `.env` and re-run.
- Passwords changed in the FreshRSS web UI are not written back to `.env`, so `credentials` would then print the old ones.
- The stack can't move between Docker daemons by itself; the old daemon's containers would keep the port and names. A `DOCKER_HOST` in the environment takes precedence over the saved `STACK_DOCKER_HOST`, so changing it in `/etc/environment` would point later runs, cron included, at a different daemon.
- With rootless Docker, the parents of a custom `--dir` are not given traverse permission. The default `/opt/rss-stack` is fine.
- `KEEP_BACKUPS` is fixed at 7. Backups live on the same disk as the data.
- Restoring a backup has not been tested.

## History and validation (2026-11-15)

The script arrived as a 390-line draft. It was reviewed by three independent agents (bash semantics, the real tools' behaviour checked against upstream source, and security), then fixed and passed through repeated `/code-review` rounds until none had actionable findings. The fixes included the weekly cron ignoring `--dir`, the FreshRSS 1.30 allowlist, input validation, DRY_RUN scope, backup failure handling and dropping Full-Text RSS. It passes `shellcheck` 0.11.0, `shfmt` 3.14.1 and `lint-bash.sh`. A 104-scenario sandbox (bubblewrap, a fake Debian, stubbed Docker and fake root) exercised install, re-install, backup rotation and failures, cron's minimal environment, validation and the rootless paths. The sandbox lived in the session scratchpad and was not kept.

The first real install on the Pi failed at `compose up`: the rootless daemon, running as `pi`, couldn't enter the root-only `/opt/rss-stack`. That run also re-enabled the system daemon Kartik had disabled on 2026-11-13, through the script's then-unconditional `systemctl enable --now docker`; Kartik disabled it again the same day. Next, the bind-mount folders had the right owner but host group `root`, which rootless Docker leaves unmapped, so FreshRSS couldn't regroup them to `www-data`. A one-time `chown 1000:1000` of the two folders plus `docker restart freshrss` fixed this install. The current script avoids all three on a new install. It wouldn't repair an install already left in that last state, though, because it only re-chowns a folder whose owner is wrong.
