# Minecraft Server Setup (Homelab Host) — 2026-08-24

Kartik asked to run a Minecraft server on the homelab host (`dell-optiplex`, 192.168.0.222), scaffolded first as a plan, then executed the same session once Kartik answered the open questions: **Paper, no plugins, port-forward (no VPN), 3-5 expected players.**

## Decisions and why

- **Paper over Vanilla.** Paper's own benchmarks show 5x+ TPS and lower CPU/memory than vanilla at higher player counts, drop-in compatible with vanilla clients, and it's the de facto standard even with zero plugins installed (Kartik doesn't want plugins now, but Paper leaves that option open later at no cost).
- **Java 25, not Java 21.** The original plan targeted Java 21 (Paper's documented requirement for the 1.20-1.21.11 line). At install time, `apt-cache policy openjdk-21-jre-headless` had **no candidate** on this Debian forky/sid host — only Java 25/26/27 packages exist in the repo now. Paper's current stable line has also moved past 1.21 to the unified `26.x` versioning (26.2 was current at setup time), which itself requires Java 25 — so this wasn't a downgrade-in-spirit, just picking the version that's both current and actually installable.
- **G1GC + Aikar's flags, not the newer ZGC guidance.** Some 2026 community guidance for Java 25/26.x servers recommends switching to Generational ZGC. That guidance is conditioned on large heaps (~32GB) and many cores — on this host (4 cores, no hyperthreading, shared with an active desktop/xrdp session, 4GB heap), ZGC's concurrent GC threads would compete with the tick thread rather than help. G1 remains Java's default collector at any version, so G1GC/Aikar's flags on Java 25 is not a compromise, just the correct choice for this hardware profile.
- **Static IP already in place.** The host's IP was fixed to `192.168.0.222/24` earlier this session (see `docs/homelab-networkmanager-plan.md`) specifically because other things, including the router's future port-forward rule, need to reach it by a fixed address.
- **Port-forward, not VPN, for internet access.** Kartik's explicit choice. This means the game port is genuinely public, which is why the firewall step (below) matters more than it otherwise would.

## What was built

1. **Java 25 headless JRE** (`openjdk-25-jre-headless`) — confirmed via `java -version`: `OpenJDK Runtime Environment (build 25.0.4+7-1-Debian)`.
2. **Dedicated `minecraft` system user**, home `/opt/minecraft`, no login shell (`useradd -r -m -U -d /opt/minecraft -s /usr/sbin/nologin minecraft`) — the server never runs as `kartik` or root.
3. **Paper 26.2, build 117** downloaded straight from PaperMC's Fill API (`fill.papermc.io`) as the `minecraft` user, SHA-256 verified against the API's own checksum before use (`9ca2ca85...9fdaa93`, matched exactly).
4. **`eula.txt`** — `eula=true`, accepted per Kartik's request (Mojang's EULA is a legal requirement, not a technical toggle).
5. **`server.properties`** — key settings: `server-port=25565`, `max-players=10` (headroom above the expected 3-5), `online-mode=true` (keeps the server on Mojang's auth path even though the port is public — this is the main thing standing between "port-forwarded" and "open to literally anyone with a cracked client"), `white-list=false` (Kartik can flip this on later and provide usernames if griefing becomes a concern), `view-distance=10`, `simulation-distance=10`, `enable-rcon=true` bound to the same interface as the game server but only actually reachable from `127.0.0.1` because of the firewall rule below (vanilla/Paper has no separate RCON-bind-address setting — the firewall is what actually restricts it).
6. **`minecraft.service`** (systemd, enabled + running) — runs Paper as the `minecraft` user with `-Xms4G -Xmx4G` (equal, per Aikar's guidance) and the full Aikar's-flags G1GC tuning set, plus `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=full`, `ProtectHome=true`, `Restart=on-failure`. Verified: world generated cleanly, `Done (20.867s)!`, listening on `*:25565` and `*:25575`, `systemctl is-enabled`/`is-active` both confirm.
7. **Host firewall (nftables)** — the host had **zero packet filtering** before this (service disabled, ruleset present but empty/policy-less). Wrote a real ruleset: default-drop on `input` and `forward`, explicit accepts for loopback, established/related connections, ICMP echo, SSH (22), and Minecraft (25565) — **25575 (RCON) is deliberately not in the allow list**, so it's unreachable from outside even though the game server binds it to all interfaces. Applied live, then validated with a **fresh, independent SSH connection** (not the one that applied the rule) plus a direct TCP reachability test from the Windows side confirming 25565 open and 25575 closed. `nftables.service` enabled for reboot persistence.
8. **Nightly backup** — `/opt/minecraft/backup.sh`, run via the `minecraft` user's crontab at 3am daily. Uses a small hand-written Python RCON client (`/opt/minecraft/rcon.py` — no `mcrcon` package exists in this Debian repo) to send `save-off` → `save-all flush`, waits 5s, tars the `world/` directory (this Paper version stores overworld/nether/end together under `world/dimensions/`, not as separate top-level folders like older versions) plus `server.properties`, then `save-on`. 7-day retention via `find -mtime +7 -delete`. Logged to `/opt/minecraft/logs/backup.log`. Ran manually twice to confirm the full RCON save cycle and tar both work before trusting it to cron; the script explicitly `cd`s into `/opt/minecraft` at the top so it doesn't depend on cron's (or any caller's) working directory.

## Open items for Kartik

- **Router port-forward**: TCP 25565 external → `192.168.0.222:25565`. Not something this session has access to configure.
- **Whitelist**: currently off. If griefing/unwanted joins become a problem after the port-forward goes live, set `white-list=true` in `server.properties` and add usernames to `whitelist.json` — deliberately left as an opt-in follow-up rather than a default, since an empty whitelist would lock out everyone including Kartik.
- **RCON password**: generated at setup time and stored only in `/opt/minecraft/server.properties` on the host — not recorded in this repo or in any persistent memory, ask Kartik directly if it's needed again.

## Follow-up (2026-08-25): `backup.sh` linted and one finding fixed

`shellcheck`, `checkbashisms`, and `dash` were installed on the host (see `docs/kvm-virtualization-setup.md`'s "Shell linting tools" section for the full install detail) and run against `/opt/minecraft/backup.sh` to check for logic errors, bashisms, and POSIX-compliance gaps.

Result: one finding, `SC2086` (info-level) on the `tar` line — `$TS` (from `TS=$(date +%Y%m%d-%H%M%S)`) was unquoted in the backup filename, `minecraft-$TS.tar.gz`. ShellCheck didn't flag the neighboring `$MC_DIR`/`$BACKUP_DIR` expansions on the same line, because it can statically prove those are safe fixed-literal assignments with no spaces or glob characters — `$TS` comes from a command substitution, which it can't prove safe, hence the flag. Realistically harmless given the fixed `date` format used, but fixed anyway since quoting costs nothing: `minecraft-"$TS".tar.gz`.

Applied with a timestamped backup kept alongside (`backup.sh.bak-20260825-130343`, owned `minecraft:minecraft`, matching the original file's hardened ownership). Re-verified clean afterward: `shellcheck` reports zero warnings, `bash -n` confirms valid syntax. `checkbashisms` reported no bashisms either before or after the fix (the script is intentionally `#!/usr/bin/env bash`, not POSIX `sh`, so `set -o pipefail` is expected and not something to change).

## Follow-up (2026-08-26): firewall was blocking xrdp (port 3389)

Kartik reported xrdp (`docs/dwm-titus-debian-port.md`'s remote-access setup) had stopped accepting connections. Root cause: this session's `nftables` ruleset (item 7 above) only explicitly allowed loopback, established/related, ICMP, SSH (22), and Minecraft (25565) — xrdp's port 3389 was never in the allow list, because xrdp had been set up and verified working *earlier the same day*, before this firewall existed. Not an xrdp misconfiguration: `xrdp.service`/`xrdp-sesman.service` were both active and listening on `*:3389` the whole time; the firewall was simply dropping the inbound connection before it reached them.

Fixed by adding `tcp dport 3389 accept` to `/etc/nftables.conf` (backed up first as `/etc/nftables.conf.bak-2026-08-26`), reloaded live with `nft -f /etc/nftables.conf`, and verified with a raw TCP connect test from the Windows side (`/dev/tcp/192.168.0.222/3389`) — succeeded. Persists across reboots since it's in the file `nftables.service` loads at boot, not just the live ruleset. Current full allow list on `enp3s0`: loopback, established/related, ICMP echo, SSH (22), xrdp (3389), Minecraft (25565); RCON (25575) remains deliberately excluded.

## Sources

- [PaperMC — Getting Started / Java requirements](https://docs.papermc.io/paper/getting-started) (Java-version-per-Minecraft-version table)
- [PaperMC Fill API](https://fill.papermc.io/) (build metadata, download URLs, checksums)
- [Aikar's original G1GC flags post](https://aikar.co/2018/07/02/tuning-the-jvm-g1gc-garbage-collector-flags-for-minecraft/) (flag set, `-Xms`/`-Xmx` equal, don't allocate all host RAM)
- [Debian wiki — Suspend](https://wiki.debian.org/Suspend) / [nftables wiki](https://wiki.nftables.org/) (ruleset structure, `systemctl mask`/`enable` patterns reused from the earlier NetworkManager work)
