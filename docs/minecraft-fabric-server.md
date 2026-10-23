# Minecraft Fabric Server with Geyser + Floodgate (This Laptop) — 2026-10-23

Kartik asked for a new Fabric server with [Geyser](https://geysermc.org/) and [Floodgate](https://geysermc.org/download/?project=floodgate), so Bedrock clients can join as well as Java ones. He chose to run it on this CachyOS laptop (`archlinux`, 192.168.0.13 on Wi-Fi at setup time) rather than `dell-optiplex`, which was unreachable at the time ("No route to host" on SSH). He also chose Minecraft 26.2 to match that host's Paper server (`docs/minecraft-server-setup.md`), not the 26.3 that Geyser's latest release targets. The Paper server is a separate server and wasn't touched.

## What was built

The server was first built by `scripts/minecraft-fabric-setup.sh`, which pinned every version for 26.2 and always installed Geyser and Floodgate. Later on 2026-10-23 that script was replaced by `scripts/minecraft-fabric/install.sh`, a standalone installer for any host. It asks for the Minecraft version and the server type (Java only, + Geyser, or + Geyser and Floodgate). It then resolves the latest stable Fabric loader and installer from meta.fabricmc.net, the required Java from Mojang's manifest, and the newest matching Fabric API, Geyser and Floodgate builds from Modrinth. Every lookup happens before anything is written. It can run the server as a systemd user unit, as a hardened system unit under a dedicated `minecraft` user, or from `start.sh` only, and it offers to install Java through pacman, apt, dnf or zypper. Every prompt also has a flag, and `--yes` runs unattended (see `--help`). It's safe to rerun. The notes below describe this laptop's install, which predates the installer. Rerunning the installer on it would take `--dir ~/Games/minecraft-fabric --mc-version 26.2 --type floodgate --service user --heap 3G`.

- **Server directory**: `~/Games/minecraft-fabric`.
- **Pinned versions** (all for 26.2): Fabric loader 0.20.1 (installer 1.1.2), Fabric API 0.161.0+26.2, Geyser-Fabric 2.11.3-b1254 and Floodgate-Fabric 2.2.6-b67. The mods come from Modrinth and are checked against Modrinth's SHA-512 before they're kept. Geyser requires Fabric API. Floodgate has no dependencies. Modrinth labels Geyser builds "beta", but that's GeyserMC's labelling convention. Geyser's own release channel is the same build stream.
- **Java**: the system's OpenJDK 27 (`/usr/bin/java`). Mojang's manifest says 26.2 needs Java 25 or newer. Java 27 rejected two of Aikar's G1GC flags (`G1RSetUpdatingPauseIntervalMillis` makes the JVM refuse to start, and `ParallelRefProcEnabled` is ignored) and deprecated `InitiatingHeapOccupancyPercent`, so the unit drops all three. It adds `--enable-final-field-mutation=ALL-UNNAMED`, the JVM's own suggested fix for a startup warning: Geyser's bundled Gson sets `final` fields reflectively, which a future Java release will block unless this is enabled. The remaining startup warning comes from JOML, which ships with Minecraft itself, calling the terminally deprecated `sun.misc.Unsafe::objectFieldOffset`. It's harmless on Java 27 and can only be fixed upstream, so it's left visible rather than suppressed.
- **Memory**: `-Xms1G -Xmx3G`, without `AlwaysPreTouch`. The cap is set with `--heap SIZE` on the installer, which defaults to half of RAM clamped to 1–4G. This laptop runs 3G. Kartik runs the client and the server on the same 14 GB machine, and Prism gives the client its default 4 GB maximum. The first version used Aikar's dedicated-host settings, `-Xms4G -Xmx4G -XX:+AlwaysPreTouch`, which claimed the whole heap at startup. During his first session (2026-10-23) the service peaked at 4.8 GB of memory, and 1.8 GB of that went to zram swap. With the new settings the server idled at 1.28 GB after booting with all 222 mods (456 MB of heap used, measured with `jcmd GC.heap_info`), and it can grow to the cap when players join. If it logs `OutOfMemoryError` or lags with players on, rerun with `--heap 4G`. If the client is the one starving, lower the cap instead, or lower the client's maximum in Prism under instance settings → Java → memory.
- **`eula.txt`**: `eula=true`, written with `--accept-eula` while setting up the server Kartik asked for, the same way as the Paper server.
- **`server.properties`**: written only if it doesn't exist yet. It sets `server-port=25565`, `online-mode=true`, `max-players=10`, `white-list=false`, view and simulation distance 10 and `motd=Fabric + Geyser`. Minecraft fills in everything else with its defaults.
- **Geyser auth**: Geyser's first-run config has `auth-type: online`, which makes Bedrock players sign in with a Java account. The script changes it to `auth-type: floodgate` in `config/Geyser-Fabric/config.yml`. Floodgate generated `config/floodgate/key.pem` on first start, and Geyser on the same server uses it without extra setup. On a fresh install the config doesn't exist until the first start. The installer therefore offers to boot the server once in the background, waits for `Done`, sends `stop` and then sets the auth type. On a test install of 26.3 this took about 20 s.
- **NetherNet**: Bedrock 26.60, due 2026-10-27, drops the RakNet transport, and Geyser still defaults to RakNet ([GeyserMC's post](https://geysermc.org/blog/preparing-for-nethernet)). The installer passes `-DgeyserTransport=nethernet` on the Java command line, which overrides the config. Geyser then serves built-in signaling on **TCP** 19132 alongside gameplay on UDP 19132. The installer warns about Geyser builds older than 1237, which have no NetherNet. A 26.3 test install logged `Transport set from system property: nethernet` and `Built-in signaling started on http://0.0.0.0:19132`.
- **`minecraft-fabric.service`**: a systemd **user** unit at `~/.config/systemd/user/`. It restarts on failure and gets 90 s to stop, so the world can save on SIGTERM. `SuccessExitStatus=143` was added after the first real stop on 2026-10-23. The JVM exits 143 (128+SIGTERM) after its shutdown hook saves the world, and systemd had been marking that as `failed`. The world files were confirmed written at the moment of exit. The save isn't logged because Log4j shuts down before the final save is written, so `latest.log` just ends at the last player event. It is installed but **not enabled**, so it doesn't start at every login on a laptop.

## Verified

Checked on 2026-10-23 after the Floodgate change and a restart:

- `systemctl --user is-active minecraft-fabric` returned `active`.
- `logs/latest.log` showed `Done`, `Started Geyser on UDP port 19132` and no errors. The only warning was Floodgate's harmless "en_ is not a supported Floodgate language", because `LANG=C.UTF-8`.
- `ss` showed Java listening on TCP `*:25565` and UDP `*:19132`.
- A Java status ping returned version `26.2`, protocol 776 and 0/10 players.
- A Bedrock RakNet ping returned `MCPE;"Fabric + Geyser";…;26.52;0;10`.

No real client has joined yet, Java or Bedrock.

## Day-to-day

```sh
systemctl --user start minecraft-fabric     # stop / restart / status likewise
systemctl --user enable minecraft-fabric    # start at login (optional)
journalctl --user -u minecraft-fabric -f    # or tail ~/Games/minecraft-fabric/logs/latest.log
```

For a live server console instead, stop the service and run `~/Games/minecraft-fabric/start.sh` in a terminal, then type `stop` to shut down cleanly. The installer generates `start.sh` (rerunning it overwrites any edits) from the same Java command as the unit. It refuses to start while the service is active, because two servers on one world would corrupt it. This was tested on 2026-10-23: it refused while the service was up, and with the service stopped it booted Fabric and Geyser, then saved and exited cleanly on `stop`.

Bedrock players connect to the laptop's IP on port 19132. Java players connect on 25565. To add mods, drop Fabric 26.2 jars into `mods/` and restart.

## Mods from the Prism instance (2026-10-23)

At Kartik's request, all 129 `.jar` files from the Prism Launcher instance `~/.local/share/PrismLauncher/instances/26.2/minecraft/mods` were copied into `mods/`. `fabric-api-0.161.0+26.2.jar` was skipped because the same version was already there, which leaves 131 jars and 222 mods once bundled sub-mods are counted. Loose non-jar files in that folder were left behind: `fabric.mod.json`, `pack.mcmeta`, `anvilrestoration_*.mixins.json`, `LICENSE_Anvian's Lib`, `Mods.zip` and Prism's `.index/`. The installer only manages its own three mods, so rerunning it leaves these alone.

The server boots with them, Geyser included. 41 of the jars declare `"environment": "client"` (Sodium, Iris-adjacent renderers, Mod Menu, minimaps' client parts and so on), and Fabric skips those on a dedicated server. The log shows 11 non-fatal errors. Ten come from `MoreVillagersRe-26.1.x`, whose advancements and a recipe reference registry keys that changed in 26.2, so those particular advancements and the recipe won't load. The eleventh is `player-death-corpses`, whose `items_add_trinkets_continued` function fails because it expects the Trinkets mod. There are also six resource-pack metadata warnings about missing `min_format`/`max_format` fields.

Java players need the same content mods as the server, which the Prism instance already has. Geyser only partly translates modded blocks and items for Bedrock players.

## Open items for Kartik

- **Switch this laptop's server to NetherNet before 2026-10-27**. It still runs Geyser on RakNet, so Bedrock players on 26.60 can't join after that date. Rerun the installer with the flags above, or add `-DgeyserTransport=nethernet` to the unit's `ExecStart` and to `start.sh`, then restart.
- **User services stop at logout**. Run `loginctl enable-linger kartik` if the server should keep running, or start at boot, without a login session.
- **Internet access**: this laptop's firewall (`firewalld`/`ufw`/`nftables`) is inactive, so LAN clients can reach both ports already. Internet players would need a router forward of TCP 25565 and both **TCP and UDP** 19132 (NetherNet) to this laptop. A forward to a laptop on DHCP Wi-Fi would also need a DHCP reservation.
- **No backups or RCON yet**, unlike the Paper server's nightly `backup.sh`.
- **Floodgate player names** get a `.` prefix by default (`config/floodgate/config.yml`, `username-prefix`). Add Bedrock players to a whitelist with `fwhitelist add <name>`.

## Sources

- [GeyserMC](https://geysermc.org/) and the Geyser README's supported-versions table (Java 26.3 current, older versions via older builds)
- [Floodgate download](https://geysermc.org/download/?project=floodgate)
- [Modrinth API](https://api.modrinth.com/v2) (version lookup and SHA-512 hashes) and [Fabric meta](https://meta.fabricmc.net/) (loader, installer and server launcher)
- Mojang's version manifest (`javaVersion.majorVersion: 25` for 26.2)
