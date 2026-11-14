# Minecraft Fabric Server with Geyser + Floodgate (This Laptop) — 2026-10-23

Kartik asked for a new Fabric server with [Geyser](https://geysermc.org/) and [Floodgate](https://geysermc.org/download/?project=floodgate), so Bedrock clients can join as well as Java ones. He chose to run it on this CachyOS laptop (`archlinux`, 192.168.0.13 on Wi-Fi at setup time) rather than `dell-optiplex`, which was unreachable at the time ("No route to host" on SSH). He also chose Minecraft 26.2 to match that host's Paper server (`docs/minecraft-server-setup.md`), not the 26.3 that Geyser's latest release targets. The Paper server is a separate server and wasn't touched. The 2026-11-14 reinstall below runs 26.3.

## Current install (2026-11-14)

After the laptop's 2026-11-09 reinstall, the server was reinstalled at 21:13 on 2026-11-14 with `scripts/minecraft-fabric/install.sh`, into `~/minecraft-fabric` rather than `~/Games/minecraft-fabric`. Its `.install-state` records Minecraft 26.3, `--type floodgate`, `--service none` (no systemd unit, `start.sh` only) and a 4G heap. The pinned builds are Fabric loader 0.20.1 (installer 1.1.2), Fabric API 0.166.2+26.3, Geyser-Fabric 2.12.1-b1302 and Floodgate-Fabric 2.2.7-b69. `mods/` holds only those three jars, and the world is new. `start.sh` passes `-DgeyserTransport=nethernet`, so this install already runs NetherNet.

The first `start.sh` run that evening was healthy. `ss` showed Java on TCP 25565 and on UDP and TCP 19132 (Geyser gameplay and NetherNet signaling). A Java client on this laptop joined from `127.0.0.1` in online mode. No Bedrock client has joined yet. Every warning it logged is benign:

- Floodgate's "en_ is not a supported Floodgate language" comes from `LANG=C.UTF-8`, and Floodgate falls back to `en_US`. `default-locale: en_US` was uncommented in `config/floodgate/config.yml` later on 2026-11-14, and a test boot of a copy of the server on spare ports no longer logged the warning. The installer now makes the same change itself (below), and leaves this already-set line alone.
- One "Can't keep up! … 2013ms or 40 ticks behind" was logged right after Geyser's 1.7 s load on the server thread, a one-off at startup.
- `Send failed, errno=101` (`ENETUNREACH`) comes from NetherNet's STUN probe trying IPv6 on a host with no IPv6 route. Geyser then asks the IPv4 STUN servers only and finds the public address.
- The JOML `sun.misc.Unsafe` warning is the one described under Java below.

The installer's own first boot, 20 s earlier, logged a TLS hostname mismatch from `discovery.minecraftservices.com` and "Services are unavailable". The `start.sh` boot had no such error, and a few minutes later that host served a valid `*.minecraftservices.com` certificate, so it looks transient. If it recurs, check DNS for that name first.

Run it with `~/minecraft-fabric/start.sh` and type `stop` to quit. For a user unit instead, rerun the installer with `--dir ~/minecraft-fabric --mc-version 26.3 --type floodgate --service user`. Without `--mc-version`, the version prompt defaults to the latest stable release. The firewall (`firewalld`, `ufw`, `nftables` and `iptables`) was still inactive on 2026-11-14, so LAN players can reach both ports.

### Floodgate locale

Floodgate-Fabric 2.2.7-b69 ships 35 translations, as `languages/texts/<language>_<COUNTRY>.properties` in its jar. When the JVM's locale isn't one of them, it logs `<locale> is not a supported Floodgate language` on every start and falls back to `en_US`. `LANG=C.UTF-8`, this laptop's default, gives Java the locale `en` with no country, so `en_`.

Since 2026-11-14, with `--type floodgate`, the installer looks for that warning in the server's `logs/latest.log`, after its first boot and on every rerun. If the warning is there, it uncomments the `# default-locale: en_US` line that Floodgate's config ships with. That's the same fix made by hand above. Floodgate was already using `en_US`, so only the warning goes away. Only Floodgate's startup check logs that exact text (`isValidLanguage`, called from `init`). A joining player whose language Floodgate lacks logs `Missing locale file:` instead, so players can't trigger the change. The setting also matters less than its name suggests. When a player joins, Floodgate loads that player's own language (`ModEventListener` calls `loadLocale` with the player's language code), so players still get messages in their own language where Floodgate has one. `default-locale` only sets the language of Floodgate's console lines and the fallback for players whose language it lacks.

The change happens at most once per install. When the installer makes it, it adds `floodgate_locale=set` to `.install-state`, keeps that line on every rerun, and never runs the step again. So commenting the line out by hand sticks; delete the state line to let the installer check again. The installer only ever uncomments that template line. A `default-locale` set by hand is kept, and a config without the line is left alone. It writes the state line before editing the config. If it can't edit the config, it warns, the install carries on, and it doesn't try again. A run before Floodgate has written its config says so and skips the step.

The log comes from the server's last start, so it reflects that start's environment, a unit's own `Environment=` lines and drop-ins included. Two cases can still pin English without need: the first boot, which runs from the installer's shell rather than the unit, and a rerun that switches `--service` before the server has started under the new mode. Either way only the console's language and the fallback change, and commenting the line out undoes it for good.

Checked on 2026-11-14 against copies of this server's files: Floodgate's generated config, the live `logs/latest.log`, which holds the warning, and `.install-state`. The step produced a config byte-identical to the hand-edited one and appended `floodgate_locale=set`. With the line then commented out again, a rerun left it commented. `scripts/minecraft-fabric/test_install.py` covers:

- a log with and without the warning, a missing log, and a missing config
- hand-set values, including one beside the template line
- a config it can't edit
- the state record, and a hand revert holding across reruns and starts that warn again
- a first boot with and without the warning
- system mode, where the log, config and state file are read and edited as `minecraft`

Three broken copies of the installer, one each without the state check, without carrying the record forward, and without the hand-set check, each fail those tests.

## What was built

The server was first built by `scripts/minecraft-fabric-setup.sh`, which pinned every version for 26.2 and always installed Geyser and Floodgate. Later on 2026-10-23 that script was replaced by `scripts/minecraft-fabric/install.sh`, a standalone installer for any host. It asks for the Minecraft version and the server type (Java only, + Geyser, or + Geyser and Floodgate). It then resolves the latest stable Fabric loader and installer from meta.fabricmc.net, the required Java from Mojang's manifest, and the newest matching Fabric API, Geyser and Floodgate builds from Modrinth. Every lookup happens before anything is written. It can run the server as a systemd user unit, as a hardened system unit under a dedicated `minecraft` user, or from `start.sh` only, and it offers to install Java through pacman, apt, dnf or zypper. The version, server type, run mode and directory questions have flags (`--mc-version`, `--type`, `--service`, `--dir`), as do the heap (`--heap`) and the EULA (`--accept-eula`); see `--help`. The other prompts have no flag of their own, and `--yes` answers each with its default, so an unattended run doesn't always finish the job. It stops with "cancelled", before touching the server directory or any unit, when the run would move an existing install to another Minecraft version, when the unit file already runs a server from another directory, or when a server port is in use and no unit for this directory holds it (the same server running from `start.sh`, for instance). It never opens the firewall or accepts the EULA. When it doesn't open an active firewalld or ufw, the summary prints a firewall warning beside the addresses. It also warns when an nftables input chain drops traffic by default, or when `nftables.service` or `iptables.service` is active but its ruleset can't be read. Reading the ruleset needs root, so the installer tries it with sudo only when the run already uses sudo (system mode or a package install), and never asks for a password to do so. It needs sudo only for a system unit, package installs, firewall changes and stopping a system unit for the same directory, so user and `start.sh`-only installs work without it. When it starts the unit, it watches it for 15 s and exits with an error, instead of `Done`, if the server didn't stay up. It enables the unit at boot only if it was already enabled, and starts the server only if this run stopped it, so a fresh `--yes` install is left stopped and not enabled. Start (and, if wanted, enable) it with `systemctl` afterwards. Reruns update the launcher and the installer's own mods, and keep the world, `server.properties` and any other mods.

The notes below describe this laptop's install, which predates the installer. Rerunning the installer on it would take `--dir ~/Games/minecraft-fabric --mc-version 26.2 --type floodgate --service user --heap 3G`, but not as it stands. With no `.install-state` file from an earlier run, the installer treats the `fabric-api-*`, `Geyser-Fabric-*` and `Floodgate-Fabric-*` jars already in `mods/` as unmanaged. It adopts one only if it is byte-for-byte (SHA-512) the build it resolves now. Unless the pinned builds below are still Modrinth's newest for 26.2, it stops with "unmanaged mods/… conflicts with …; move it out of mods/ before rerunning" and leaves the server unchanged, so move those three jars out of `mods/` first. As of 2026-11-14, neither `~/Games/minecraft-fabric` nor the `minecraft-fabric` user unit exists on this laptop, which was reinstalled on 2026-11-09 (see `docs/handoff.md`). The list below records the install as it was before then, and so do the **Verified** and **Mods from the Prism instance** sections.

- **Server directory**: `~/Games/minecraft-fabric`.
- **Pinned versions** (all for 26.2): Fabric loader 0.20.1 (installer 1.1.2), Fabric API 0.161.0+26.2, Geyser-Fabric 2.11.3-b1254 and Floodgate-Fabric 2.2.6-b67. The mods come from Modrinth and are checked against Modrinth's SHA-512 before they're kept. Geyser requires Fabric API. Floodgate has no dependencies. Modrinth labels Geyser builds "beta", but that's GeyserMC's labelling convention. Geyser's own release channel is the same build stream.
- **Java**: the system's OpenJDK 27 (`/usr/bin/java`). Mojang's manifest says 26.2 needs Java 25 or newer. Java 27 rejected two of Aikar's G1GC flags (`G1RSetUpdatingPauseIntervalMillis` makes the JVM refuse to start, and `ParallelRefProcEnabled` is ignored) and deprecated `InitiatingHeapOccupancyPercent`, so the unit drops all three. It adds `--enable-final-field-mutation=ALL-UNNAMED`, the JVM's own suggested fix for a startup warning: Geyser's bundled Gson sets `final` fields reflectively, which a future Java release will block unless this is enabled. The remaining startup warning comes from JOML, which ships with Minecraft itself, calling the terminally deprecated `sun.misc.Unsafe::objectFieldOffset`. It's harmless on Java 27 and can only be fixed upstream, so it's left visible rather than suppressed.
- **Memory**: `-Xms1G -Xmx3G`, without `AlwaysPreTouch`. The cap is set with `--heap SIZE` on the installer, which defaults to half of RAM clamped to 1–4G. This laptop runs 3G. Kartik runs the client and the server on the same 14 GB machine, and Prism gives the client its default 4 GB maximum. The first version used Aikar's dedicated-host settings, `-Xms4G -Xmx4G -XX:+AlwaysPreTouch`, which claimed the whole heap at startup. During his first session (2026-10-23) the service peaked at 4.8 GB of memory, and 1.8 GB of that went to zram swap. With the new settings the server idled at 1.28 GB after booting with all 222 mods (456 MB of heap used, measured with `jcmd GC.heap_info`), and it can grow to the cap when players join. If it logs `OutOfMemoryError` or lags with players on, rerun with `--heap 4G`. If the client is the one starving, lower the cap instead, or lower the client's maximum in Prism under instance settings → Java → memory.
- **`eula.txt`**: `eula=true`, written with `--accept-eula` while setting up the server Kartik asked for, the same way as the Paper server.
- **`server.properties`**: written only if it doesn't exist yet. It sets `server-port=25565`, `online-mode=true`, `max-players=10`, `white-list=false`, view and simulation distance 10 and `motd=Fabric + Geyser`. Minecraft fills in everything else with its defaults.
- **Geyser auth**: Geyser's first-run config has `auth-type: online`, which makes Bedrock players sign in with a Java account. With `--type floodgate` the script changes `java.auth-type` (`remote.auth-type` in older configs) to `floodgate` in `config/Geyser-Fabric/config.yml`. With `--type geyser` it only changes a leftover `floodgate` back to `online`, so a deliberate `offline` is kept. Floodgate generated `config/floodgate/key.pem` on first start, and Geyser on the same server uses it without extra setup. On a fresh install the config doesn't exist until the first start. Once the EULA is accepted, the installer therefore offers to boot the server once in the background and waits for `Done`. It then sends the JVM SIGTERM, whose shutdown hook saves the world the same way a systemd stop does (it's killed if that takes over 2 minutes), and sets the auth type. On a test install of 26.3 this took about 20 s.
- **NetherNet**: Bedrock 26.60, due 2026-10-27, drops the RakNet transport, and Geyser still defaults to RakNet ([GeyserMC's post](https://geysermc.org/blog/preparing-for-nethernet)). The installer passes `-DgeyserTransport=nethernet` on the Java command line, which overrides the config. Geyser then serves built-in signaling on **TCP** 19132 alongside gameplay on UDP 19132. The installer warns about Geyser builds older than 1237, which have no NetherNet. A 26.3 test install logged `Transport set from system property: nethernet` and `Built-in signaling started on http://0.0.0.0:19132`.
- **`minecraft-fabric.service`**: a systemd **user** unit at `~/.config/systemd/user/`. It restarts on failure and gets 90 s to stop, so the world can save on SIGTERM. Units the installer writes also set `StartLimitIntervalSec=600` and `StartLimitBurst=5`. With `RestartSec=10`, systemd's default limit (5 starts in 10 s) can never trip, so a server that keeps crashing would restart forever. With these values, systemd refuses the 6th start when 5 × (uptime + 10 s) < 600 s, so a server that keeps dying within about 110 s of starting is marked failed after 5 starts. Manual starts count too; `systemctl reset-failed` clears the count. `SuccessExitStatus=143` was added after the first real stop on 2026-10-23. The JVM exits 143 (128+SIGTERM) after its shutdown hook saves the world, and systemd had been marking that as `failed`. The world files were confirmed written at the moment of exit. The save isn't logged because Log4j shuts down before the final save is written, so `latest.log` just ends at the last player event. It is installed but **not enabled**, so it doesn't start at every login on a laptop.

## Verified

Checked on 2026-10-23 after the Floodgate change and a restart:

- `systemctl --user is-active minecraft-fabric` returned `active`.
- `logs/latest.log` showed `Done`, `Started Geyser on UDP port 19132` and no errors. The only warning was Floodgate's harmless "en_ is not a supported Floodgate language", because `LANG=C.UTF-8`.
- `ss` showed Java listening on TCP `*:25565` and UDP `*:19132`.
- A Java status ping returned version `26.2`, protocol 776 and 0/10 players.
- A Bedrock RakNet ping returned `MCPE;"Fabric + Geyser";…;26.52;0;10`.

No real client has joined yet, Java or Bedrock.

## Day-to-day

The current install has no unit. Run `~/minecraft-fabric/start.sh` in a terminal for the server and its console, and type `stop` to shut down cleanly. After a rerun with `--service user`, the unit works like this:

```sh
systemctl --user start minecraft-fabric     # stop / restart / status likewise
systemctl --user enable minecraft-fabric    # start at login (optional)
journalctl --user -u minecraft-fabric -f    # or tail ~/minecraft-fabric/logs/latest.log
```

For a live console beside a unit, stop the service and run `start.sh` instead. The installer generates `start.sh` (rerunning it overwrites any edits) from the same Java command as the unit. It refuses to start while the service is active, because two servers on one world would corrupt it. This was tested on 2026-10-23: it refused while the service was up, and with the service stopped it booted Fabric and Geyser, then saved and exited cleanly on `stop`.

Bedrock players connect to the laptop's IP on port 19132. Java players connect on 25565. To add mods, drop Fabric jars built for the server's Minecraft version (26.3 now) into `mods/` and restart.

## Mods from the Prism instance (2026-10-23)

At Kartik's request, all 129 `.jar` files from the Prism Launcher instance `~/.local/share/PrismLauncher/instances/26.2/minecraft/mods` were copied into `mods/`. `fabric-api-0.161.0+26.2.jar` was skipped because the same version was already there, which leaves 131 jars and 222 mods once bundled sub-mods are counted. Loose non-jar files in that folder were left behind: `fabric.mod.json`, `pack.mcmeta`, `anvilrestoration_*.mixins.json`, `LICENSE_Anvian's Lib`, `Mods.zip` and Prism's `.index/`. The installer only manages its own three mods, so rerunning it leaves these alone.

The server boots with them, Geyser included. 41 of the jars declare `"environment": "client"` (Sodium, Iris-adjacent renderers, Mod Menu, minimaps' client parts and so on), and Fabric skips those on a dedicated server. The log shows 11 non-fatal errors. Ten come from `MoreVillagersRe-26.1.x`, whose advancements and a recipe reference registry keys that changed in 26.2, so those particular advancements and the recipe won't load. The eleventh is `player-death-corpses`, whose `items_add_trinkets_continued` function fails because it expects the Trinkets mod. There are also six resource-pack metadata warnings about missing `min_format`/`max_format` fields.

Java players need the same content mods as the server, which the Prism instance already has. Geyser only partly translates modded blocks and items for Bedrock players.

## Open items for Kartik

- ~~**Switch this laptop's server to NetherNet before 2026-10-27**.~~ Moot as of 2026-11-14: the RakNet install is gone, and the new `~/minecraft-fabric` install runs NetherNet.
- **User services stop at logout**, which matters only after a switch to `--service user`. Then run `loginctl enable-linger kartik` if the server should keep running, or start at boot, without a login session.
- **Internet access**: this laptop's firewall (`firewalld`, `ufw`, `nftables` and `iptables`, all inactive on 2026-11-14) lets LAN clients reach both ports already. Internet players would need a router forward of TCP 25565 and both **TCP and UDP** 19132 (NetherNet) to this laptop. A forward to a laptop on DHCP Wi-Fi would also need a DHCP reservation.
- **No backups or RCON yet**, unlike the Paper server's nightly `backup.sh`.
- **Floodgate player names** get a `.` prefix by default (`config/floodgate/config.yml`, `username-prefix`). Add Bedrock players to a whitelist with `fwhitelist add <name>`.

## Sources

- [GeyserMC](https://geysermc.org/) and the Geyser README's supported-versions table (Java 26.3 current, older versions via older builds)
- [Floodgate download](https://geysermc.org/download/?project=floodgate)
- [Modrinth API](https://api.modrinth.com/v2) (version lookup and SHA-512 hashes) and [Fabric meta](https://meta.fabricmc.net/) (loader, installer and server launcher)
- Mojang's version manifest (`javaVersion.majorVersion: 25` for 26.2)
