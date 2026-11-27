# Private Minecraft server behind Twingate (Docker Compose)

`scripts/minecraft-twingate/minecraft-twingate.sh` automates the guide Kartik saved as `~/Downloads/minecraft-docker-twingate.md`, which follows Twingate's [Minecraft Server with Twingate](https://www.twingate.com/docs/minecraft-server). It runs `itzg/minecraft-server` and `twingate/connector:1` together on a private Docker bridge network. The Connector only makes outbound connections, so no port is published, nothing is forwarded on the router, and port 25565 never faces the internet or the LAN. Players reach the server through the Twingate Client at a fixed private address (`172.30.0.10` by default).

The script is POSIX `sh`, so it runs under `dash`, `bash`, BusyBox `ash` or any other POSIX shell. It installs Docker Engine and the Compose plugin when they're missing, on the Arch, Fedora/EL and Debian/Ubuntu families and their derivatives. This is a separate setup from the port-forwarded Paper server (`docs/minecraft-server-setup.md`) and the Fabric server on the laptop (`docs/minecraft-fabric-server.md`).

## Before you run it

Your tenant's address is the host part of the Admin Console URL. It can be `NAME.twingate.com` or a regional one such as `NAME.us2.twingate.com`. Pass it whole to `--network`. The Connector gets it as `TWINGATE_URL=https://<address>`, the variable Twingate's own [Helm chart](https://github.com/twingate/helm-charts) sets from `connector.network` plus `connector.url` (default `twingate.com`). A bare `NAME` means `NAME.twingate.com`. A VM run with a made-up `….us2.twingate.com` tenant showed the Connector taking `TWINGATE_URL` and going to `State: Authentication`.

In the Twingate Admin Console, go to **Remote Networks**, then **Add Remote Network** ("On Premise"). Open its Connector, choose **Docker** and **Generate Tokens**. Each Connector needs its own Access Token and Refresh Token. You also need the tenant name, the `NAME` in `https://NAME.twingate.com`. The host needs at least 2 GB RAM, 2 cores and 10 GB of disk. Vanilla Minecraft for up to 10 players fits in a 2 GB heap; heavy modpacks need 6 to 8 GB.

## Commands

Run as root (`sudo`, or `pkexec` on Kartik's machines). Pass the tokens through the environment, or leave them out and the script prompts for them without echoing. They are never accepted as flags, so they stay out of `ps` and shell history. Plain `sudo` resets the environment, so either set them after `sudo` as below or use `sudo --preserve-env=TG_ACCESS_TOKEN,TG_REFRESH_TOKEN`. Run as a normal user, the script stops and prints the `sudo --preserve-env=...` command to use, naming every setting you exported.

```sh
sudo TG_ACCESS_TOKEN=... TG_REFRESH_TOKEN=... \
  scripts/minecraft-twingate/minecraft-twingate.sh install --network mytenant --accept-eula
sudo scripts/minecraft-twingate/minecraft-twingate.sh status     # containers, readiness, the Resource address
sudo scripts/minecraft-twingate/minecraft-twingate.sh update     # re-apply .env and flags, pull newer images, recreate
scripts/minecraft-twingate/minecraft-twingate.sh install --dry-run --accept-eula   # preview to a temp folder, no root
```

`install` identifies the distribution, installs Docker unless a real Engine (`dockerd`) and a working `docker compose` are already there, enables and starts the daemon, and writes `/opt/minecraft-server/.env` (mode 600) and `compose.yaml`. It then pulls the images, starts both containers and waits up to `MC_WAIT` seconds (default 600) for the server log's `Done (` line. The first start downloads the server JAR, so it's slow. If Minecraft's restart count rises during the wait, for example because of a bad `--version`, the script stops at once instead of waiting it out. It then gives the Connector 60 seconds to log `State: Online`. A Connector with bad tokens doesn't crash: it keeps running and logs `State: Error`, so the script reads the Connector's own state lines rather than Docker's status. Finally the script checks that neither container is restarting, then prints the Admin Console steps that remain. It exits 1 if Minecraft didn't become ready within `MC_WAIT`, so automation can tell. `status` is read-only and lenient: it doesn't prompt or validate `.env`, so a bad hand edit can't hide the containers' state.

Readiness only counts the current run. `.State.Running` stays true while Docker restarts a crashing container, and `docker logs` keeps every earlier run's output. So the script reads `.State.Status`, compares `RestartCount`, and limits log searches with `--since` set to the container's `StartedAt`. Minecraft counts as ready when the image's own `mc-health` check reports healthy, or when the current run has logged `Done (`. The health check covers a long-running server whose `Done` line has rotated out of the 3 × 10 MB of logs Docker keeps. The log line is the faster signal on a first start, because the health check waits out a 2-minute start period. The Connector's Docker health check is no help, because it reports healthy even with rejected tokens. Once its `State:` lines have rotated out, the script warns instead of failing.

`install` and `update` warn while `MC_VERSION` is `LATEST` and a world already exists. A new Minecraft release upgrades the world on the next recreate, worlds can't be downgraded, and clients on the old version can't join. Back up `data/` or pin `--version`. `update` also repeats the RAM check, so a larger `--memory` gets the same warning as on install.

`--dry-run` never writes to `--dir`. It reads any `.env` already there, but always writes the preview to a fresh `mktemp -d` folder, with the tokens replaced by `REDACTED`, and prints that folder's path. A `.env` left in `--dir` would count as an install, and `update` would start what was only previewed. Run it as root against a root-owned live `.env` (mode 600), or the script stops with "Cannot read". A preview needs no real tokens: it uses placeholders when none are set.

Distribution detection only runs when Docker has to be installed. A host that already has `dockerd` and a working `docker compose` works on any distribution, Alpine or openSUSE included, and `--codename` just draws a warning there. `--dir` must be a dedicated folder. The script refuses:

- `/`, a bare system folder such as `/etc` or `/opt`, a folder one level under `/home`, `/usr` or `/var` (a home directory, `/usr/local`, `/var/lib`), or a path with `.` or `..` parts;
- a folder whose `compose.yaml` or `.env` this script didn't write, or that holds a `docker-compose.yml`, `docker-compose.yaml` or `compose.yml`;
- a folder whose `data/` already holds files while its `.env` isn't this script's. The container chowns `/data` to UID 1000 and `:Z` relabels it, which would break another app's files.

`--version latest` and `snapshot` are accepted in any case and saved in upper case. After starting a non-systemd Docker, the script retries `docker info` for up to 30 seconds, because init scripts can return before the socket exists.

The server gets `stop_grace_period: 75s`. The image waits up to 60 seconds for its final world save when it's stopped, and Docker's default of 10 seconds would kill it partway through a large world's save. The first `update` after this change recreates the server container to apply it.

The container names `minecraft-server` and `twingate-connector` are fixed, so there is one stack per host. `install` or `update` from a second `--dir` stops before writing anything when those containers already belong to another folder or to no Compose project. Otherwise Compose would repoint the running server at the new folder's empty world.

Settings resolve the same way `scripts/rss-stack/rss-stack.sh` does: a flag or environment variable wins, then the value saved in `.env`, then the default. Re-running `install` is safe. To change a setting, edit `.env` or pass the flag to `update`. Repeat `--dir` on every command if you don't use the default.

| Flag | Variable | Default | Notes |
| --- | --- | --- | --- |
| `--dir` | `MC_DIR` | `/opt/minecraft-server` | absolute, no spaces |
| `--network` | `TG_NETWORK` | prompt | Twingate tenant: `NAME`, or its full address such as `NAME.us2.twingate.com`; regional tenants need the full address |
| none | `TG_ACCESS_TOKEN`, `TG_REFRESH_TOKEN` | prompt | Connector tokens |
| `--memory` | `MC_MEMORY` | `2G` | Java heap, `NG` or `NM` |
| `--type` | `MC_TYPE` | `VANILLA` | any itzg `TYPE`: `PAPER`, `FORGE`, `FABRIC`... |
| `--version` | `MC_VERSION` | `LATEST` | such as `1.21.1` |
| `--subnet` | `MC_SUBNET` | `172.30.0.0/24` | a /24; the server takes `.10` |
| `--accept-eula` | `MC_EULA=TRUE` | prompt | Mojang's EULA; required |
| none | `MC_DIFFICULTY`, `MC_MAX_PLAYERS`, `MC_MOTD`, `MC_OPS`, `MC_SEED` | `normal`, `10`, "Private Minecraft Server", none, random | |
| none | `MC_IMAGE_TAG` | `latest` | itzg image tag: `java8`, `java11`, `java16`, `java17`, `java21`, `java25`. Old Forge needs an old Java; current Minecraft (26.x) needs Java 25 |
| none | `MC_WAIT` | `600` | seconds to wait for the server; not saved |

Every value is validated and written single-quoted, which Compose's `.env` parser reads literally. That's why `MC_MOTD` and `MC_SEED` can't contain `'`, `$` or `\`: Compose treats `\'` as an escaped quote even inside single quotes. When you edit `.env` by hand, keep the `KEY='value'` form. The script also reads `KEY="value"` and `KEY=value`, but not `export`, spaces around `=` or comments after a value. `MC_EULA` accepts any capitalisation of `true`. Docker hands out dynamic addresses, the Connector's included, only from the top half of the /24 (`ip_range` `.128/25`, saved as `MC_IP_RANGE`), so the server's fixed `.10` can never be taken. When `update` or a re-run of `install` changes the subnet or the range, the script runs `compose down` before `up`, so Compose rebuilds the network even on older releases that would reuse it. The world is a bind mount and stays. Change `--subnet` only if `172.30.0.0/24` collides with a network the host already routes, such as a VPN, the LAN or another Compose project. Only private (RFC 1918) /24s are accepted: `10.x`, `172.16`-`172.31.x` and `192.168.x`. A public or loopback range would shadow real routes on the host. The Resource address in Twingate then changes to match.

## Distribution support

Package and repository names were checked on 2026-11-27 against Docker's install pages for [Debian](https://docs.docker.com/engine/install/debian/), [Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Fedora](https://docs.docker.com/engine/install/fedora/), [RHEL](https://docs.docker.com/engine/install/rhel/) and [CentOS](https://docs.docker.com/engine/install/centos/), and against the [Arch Wiki](https://wiki.archlinux.org/title/Docker) and the Arch package database. They were scraped with Firecrawl through Composio, and the Arch names were also confirmed with `pacman -Si` on the laptop.

| Family | Detected by | Packages | Repository |
| --- | --- | --- | --- |
| Arch, CachyOS, Manjaro, EndeavourOS, Arch ARM | `arch` or `archarm` in `ID`/`ID_LIKE` | `docker docker-compose` (29.10.1 and 5.8.0 on 2026-11-27) | distro `extra` |
| Ubuntu, Mint, Pop!_OS, Zorin | `ubuntu` in `ID`/`ID_LIKE`; suite from `UBUNTU_CODENAME` | `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` | `download.docker.com/linux/ubuntu`, deb822 `docker.sources` |
| Debian 12/13 (and 14 once stable), Raspberry Pi OS, LMDE, other derivatives | `debian`/`raspbian`; suite from `--codename`, `DEBIAN_CODENAME`, a stable Debian's own `VERSION_CODENAME` or `/etc/debian_version` | same as Ubuntu | `download.docker.com/linux/debian` |
| Fedora 43-45, Nobara, Ultramarine | `PLATFORM_ID=platform:fNN`, or no `PLATFORM_ID` and a two-digit `VERSION_ID` | same as Ubuntu | `linux/fedora/docker-ce.repo` |
| RHEL 8-10 | `ID=rhel`, `PLATFORM_ID=platform:el8`/`el9`/`el10` (or `VERSION_ID` 8-10) | same as Ubuntu | `linux/rhel/docker-ce.repo` |
| Rocky, Alma, CentOS Stream, Oracle | the same EL test | same as Ubuntu | `linux/centos/docker-ce.repo` |

Some choices need explaining. On Arch, the script runs `pacman -S --needed` without `-y`, because refreshing the databases without upgrading would be a partial upgrade. Nor does it run a full `-Syu` on its own. If a package fetch fails with a 404, as it did on the stale Arch cloud image, run `pacman -Syu` yourself. Reboot afterwards if the kernel was upgraded, because Docker needs the running kernel's modules. Then re-run. On the RPM side it downloads the `.repo` file with `curl` rather than `dnf config-manager`, whose syntax differs between dnf4 (EL) and dnf5 (Fedora 41+). RPM families are split by `PLATFORM_ID`, not `ID_LIKE`, because Nobara lists `rhel` in `ID_LIKE` although it's Fedora-based. Fedora 45 no longer sets `PLATFORM_ID`. The test VM showed this, so without one the `VERSION_ID` major decides instead: 8 to 10 is EL, two digits is Fedora. EL7 has no `PLATFORM_ID` and `VERSION_ID=7`, so it's refused, as are Amazon Linux (`platform:al2023`, or `VERSION_ID=2`) and anything else Docker doesn't publish RPMs for. Debian derivatives often set their own `VERSION_CODENAME`: Kali's is `kali-rolling` and LMDE's is `faye`. They are mapped to a Debian suite, and when that isn't possible (Kali), the script stops and asks for `--codename trixie`. On Debian itself, a stable release sets `VERSION_ID`, so any stable codename is used, which covers forky once it's released. Testing and unstable don't set `VERSION_ID`, so they're refused with the same hint. A `--codename` is used as given.

The conflict lists start from Docker's docs. On Debian they cover `docker.io`, `podman-docker`, `containerd` and `runc`, and on RHEL also `podman` and `runc`. The script adds what those docs leave out, taken from the package specs:

- On Fedora, its own `moby-engine`, `docker-cli`, `docker-compose`, `docker-buildx` and `podman-docker`. All of them conflict with `docker-ce` or its plugins, and `dnf remove docker` doesn't match `moby-engine`.
- `podman-docker` on every EL.
- `podman-docker` on Arch, where `pacman --noconfirm` would otherwise answer its removal prompt with no.

If any of these is installed, the script stops and names it. It removes them only with `--replace-conflicts`, since on RHEL that means removing Podman.

Packages are left alone only when `dockerd` exists and `docker compose` works. The `dockerd` test matters because podman-docker's `docker` shim also answers `docker compose version`, through `podman compose`, but has no `docker.service`. Fedora's `moby-engine` with `docker-compose` passes the test, so it's kept.

On Debian, the script also stops if another apt source already points at `download.docker.com`, such as a `docker.list` from older Docker docs. A different `Signed-By` path there makes every apt command fail ("Conflicting values set for option Signed-By"). It names the files rather than deleting them. An entry that uses the same `/etc/apt/keyrings/docker.asc` key only draws apt's "configured multiple times" warning, so it's allowed through. This check runs before any package is removed, so stopping here never leaves the host without its old Docker. On every family, conflicting packages are removed only after Docker's packages have been downloaded:

- **Debian:** `apt-get update` succeeds with the repo, then `apt-get install --download-only` fetches the packages.
- **RPM:** `dnf makecache --repo docker-ce-stable` succeeds, then `dnf install --downloadonly --allowerasing` fetches them. `--allowerasing` only lets the resolver plan around the conflicts; a download-only run removes nothing.
- **Arch:** `pacman -Sw` downloads them.

So a release Docker doesn't publish yet, a mirror error or a network fault fails while the old engine is still in place. `--dry-run` on a host with conflicts warns that a real install would stop there, instead of stopping the preview. `--replace-conflicts` uses the package manager's normal remove, which also takes out packages that depend on the conflicting ones (on RHEL, removing `podman` takes `podman-docker` with it). A snap-installed Docker on Ubuntu is refused, because it has no `dockerd` on `PATH` and would otherwise get a second engine beside it.

`podman-docker` turns `/run/docker.sock` into a link to Podman's socket and leaves the link behind when removed. When the script finds a link into a `podman` folder, it removes it and restarts Docker, so the CLI reaches the real daemon. Any other link is left alone, because someone set it up on purpose. `update` starts the daemon and waits for it too, so a stopped Docker after a reboot is brought up rather than read as "no containers". `compose up` runs without `--remove-orphans`, because the project name `minecraft-twingate` is fixed and another stack with that name shouldn't lose containers. `--codename`, `--replace-conflicts` and `--dry-run` are install-only and refused on `update` and `status`. Repeated slashes in `--dir` are collapsed, so the folder matches the path Compose records. Docker's signing keys are trusted on first download over HTTPS, the same as in Docker's own instructions. `dnf -y` accepts the RPM key without showing a prompt. Its fingerprint should be `060A 61C5 1B55 8A7F 742B 77AA C52F EB6B 621E 9F35`.

If Docker's repo turns out not to serve the release, the script puts the repo file back as it was and stops: `docker.sources` on Debian after `apt-get update` fails, `docker-ce.repo` on RPM after the download or `makecache` fails. A file that existed before is restored from a copy kept outside the repo folder, and a file this run created is removed. That keeps the host's package manager working. On a 32-bit Raspberry Pi OS (`ID=raspbian`), the script uses Debian's `armhf` packages, as Docker's [Raspberry Pi OS page](https://docs.docker.com/engine/install/raspberry-pi-os/) now advises, because its own `raspbian` repo got no new major version after v28. ARMv6 boards (Pi 1, Zero, Zero W) have no official packages and are refused. `--codename` is refused outside the Debian/Ubuntu family.

The daemon is started with `systemctl enable --now docker`, or with `rc-update` and `rc-service` on OpenRC, or with `service` otherwise. Under systemd it first checks that a system `docker.service` exists. `dockerd` on `PATH` without one means rootless Docker or Docker Desktop, which this script doesn't support, and it says so. On OpenRC it checks that `/etc/init.d/docker` exists. Arch's `docker` package ships no OpenRC script, so on Artix install `docker-openrc` first. No firewall rule is added or needed, since nothing is published. The data bind mount carries `:Z`, so it works with SELinux enforcing on Fedora and EL. On other hosts the flag does nothing.

## After the script

1. In the Admin Console, the Connector's Controller and Relay statuses should both say **Connected**.
2. **Resources**, then **Add Resource** on the Remote Network: address `172.30.0.10` (or your subnet's `.10`), TCP port `25565`. Java Edition needs no UDP.
3. Invite players under **Team**, put them in a **Minecraft Players** group, and on the Resource replace **Everyone** with that group. Removing someone from the group cuts their access immediately, so no Minecraft allowlist is needed.
4. Players install the [Twingate Client](https://www.twingate.com/download), sign in to `NAME.twingate.com`, and add the server `172.30.0.10` under **Multiplayer**. The Client has to stay connected while they play.

For a terminal UI over these commands, with live status, the server log and a settings form, see [minecraft-tui.md](minecraft-tui.md).

## A Twingate Client on the same host

Running the Twingate Client on the machine that hosts the stack breaks the server's internet access unless the script steps in. Once the Resource exists, the Client routes `172.30.0.10/32` into its tunnel (`dev sdwan0`, metric 25). That route is more specific than Docker's `172.30.0.0/24` bridge route, so it also catches the internet's replies to the server once they're un-NATed. The server can then reach nothing outside: players are disconnected with "Authentication servers are down. Please try again later. Sorry!", because it can't check logins with Mojang, and a first start can't download the server. The Connector, at `.129`, isn't affected. `ip route get 172.30.0.10 from <any public IP> iif <uplink>` shows `dev sdwan0` when this is happening.

So the bridge has a fixed name, `mc-twingate0`, and `install` and `update` add `172.30.0.10/32 dev mc-twingate0 metric 1`, which wins over the Client's route. They create the network with `compose up --no-start` and add the route before the containers start. A player on the host itself then reaches the server directly instead of through Twingate, which needs nothing from the Client. The route goes away with the bridge, so on systemd hosts the script also writes and enables `/etc/systemd/system/minecraft-twingate-route.service`. It's a oneshot unit, wanted by and part of `docker.service`, that waits up to 60 seconds for the bridge and adds the route again. If the stack's network no longer exists, it exits without doing anything, so a removed stack doesn't leave a failed unit behind. Without systemd, the script warns and `update` has to be run after each reboot. The route is added whether or not a Client is present, since it matches what Docker's own bridge route does anyway. Adding it is best effort: if it fails, the script warns and still starts the stack.

A stack installed before this change has a bridge named `br-<id>`. The next `update` pulls the images first, then sees the missing name, takes the stack down and rebuilds the network.

Two gaps remain. The unit runs only when Docker starts, so a manual `docker compose down` and `up` while Docker keeps running drops the route until the next `update` or reboot. `status` warns when it's missing. And after a reboot, Docker restarts the containers before the unit has added the route. If the Client is already connected by then and the server needs a download as it starts, that start fails, and Docker restarts the container once the route is in. To remove the stack entirely, also run `systemctl disable --now minecraft-twingate-route.service` and delete the unit file.

## Troubleshooting

All commands below take `--project-directory /opt/minecraft-server` (or your `--dir`).

- **The server crashes or restarts.** It is usually out of memory. Raise `MC_MEMORY` and make sure the host has that much free; the script warns when the heap plus about 768 MB exceeds total RAM. Check `docker compose logs minecraft`.
- **The Connector is offline or restarting.** Check the tokens in `.env` and that the host has outbound internet access, then `docker compose logs twingate-connector`. Each Connector needs its own token pair.
- **A player can't connect.** Check that their Client is connected, that the Resource shows in it (which means they're in the group), and that they're on Java Edition. Bedrock (UDP 19132) and Forge have their own Twingate guides.
- **"Authentication servers are down" when joining.** The server can't reach Mojang. If a Twingate Client runs on the host, check `status` for the route warning and run `update` (see [A Twingate Client on the same host](#a-twingate-client-on-the-same-host)).
- **`Pool overlaps with other one on this address space`.** The subnet collides with another network: use `--subnet`.
- **Backups.** The world lives in `/opt/minecraft-server/data`. Back it up regularly; the script doesn't.

## Validation

Checked on 2026-11-27.

**Static checks.** `lint-bash.sh` passes (shellcheck, `shfmt -d`, `sh -n`), `checkbashisms -f -p` is clean, and the generated `compose.yaml` passes `validate-config.sh`.

**Dry runs on the laptop.** `--dry-run` ran under real `dash` 0.5.13 with 21 fake `os-release` files, supplied through `OS_RELEASE` and `DEBIAN_VERSION_FILE`, which exist only for tests.

- It picked the right repository and suite for Arch, CachyOS, Manjaro ARM, Debian 13, Raspbian 12, LMDE 6, Ubuntu 24.04, Mint 22.1, Debian 14 (as a future stable), Fedora 43 and 45, Nobara, RHEL 10, Rocky 9 and a CentOS Stream 10 without `PLATFORM_ID`.
- It refused Debian testing, Kali without `--codename`, CentOS 7, Amazon Linux 2 and 2023, and openSUSE, each with a clear message.
- A dry run against an existing `.env` left it untouched. Hand-edited `.env` values with double quotes, trailing blanks and a lowercase `MC_EULA=true` were read correctly.
- Bad input exits 1 with a message. That covers a backslash in `MC_MOTD`/`MC_SEED`, a bad `MC_IMAGE_TAG` or `MC_WAIT`, a missing tenant with no terminal, a `--dir` of `/`, `/etc`, `/opt/` or with `.` or `..` parts, a folder holding another app's `compose.yaml`, every other validation error, a missing value, an unknown flag or command, a non-root run, and a missing token with no terminal.

**Real installs in three throwaway VMs.** These ran as rootless QEMU/KVM guests on the laptop, from checksum-verified official cloud images, with fake Twingate tokens.

- **Debian 13, run under `dash`.** A fresh install set up Docker 29.10.1 from Docker's repo, and Minecraft reached `Done`. `update` with an impossible `--version 9.99.99` stopped as soon as the server crashed, and `status` works. A leftover `docker.list` was refused with the file named, and removing the Compose plugin and re-running reinstalled it.
- **Fedora 45, SELinux enforcing.** A fresh install set up `docker-ce` 29.10.1, and Minecraft reached `Done` with the `:Z` mount. Fedora's `moby-engine` plus `docker-compose` was kept and worked. `moby-engine` without Compose was refused, naming `moby-engine docker-cli docker-buildx`, and `--replace-conflicts` swapped those for Docker's packages.
- **Arch.** The stale cloud image's sync database gave 404s, so the script stopped with its `pacman -Syu` hint. After `-Syu` and a reboot, `podman-docker` was refused. `--replace-conflicts` removed it and installed `docker` 29.10.1 and `docker-compose` 5.8.0, and Minecraft reached `Done`.
- **Connector, every run:** with fake tokens it stays `running` and logs `State: Offline → Authentication → Error`. The script stopped with the tokens message, and no host port was listening on 25565.

A fourth round checked the second review's fixes:

- On Debian, `MC_IMAGE_TAG=java21` pulled the `java21` image. Minecraft 26.3 then failed with `UnsupportedClassVersionError` (it needs Java 25), and the script stopped at the first restart. Switching back to `latest` restored it.
- On Fedora, an `update` with nothing changed found the server ready through the health check at once. The Connector window made it about 60 seconds in total.
- On Arch, `install --dry-run --memory 8G` against the live install wrote to a temp folder and left the live `.env` byte-identical.

A fifth round checked the third review's fixes on Debian:

- `install --dir /opt/mc2`, with the first stack running from `/opt/minecraft-server`, stopped before writing anything, and the running server kept its folder.
- `status` still reported state after `.env` was hand-edited to an invalid `MC_DIFFICULTY='Hard'`.
- A non-root run printed the full root hint, flags included.

On the laptop, dry runs confirmed the rest:

- A saved `MC_MOTD='"Welcome"'` keeps its double quotes when read back.
- Foreign `.env`, foreign `docker-compose.yml` and unreadable `.env` folders are refused.
- Public, loopback and out-of-range `172.x` subnets are refused.
- A preview of a live install has the tokens redacted.

A sixth round checked the fourth review's fixes:

- On Fedora, Docker's packages were swapped for `moby-engine` alone. `install --replace-conflicts` then fetched Docker's repo and passed `makecache` before removing `moby-engine docker-cli docker-buildx`, then installed `docker-ce`, and Minecraft reached `Done`.
- On Arch, Docker was swapped for `podman-docker`. `pacman -Sw` downloaded Docker with `podman-docker` still installed, then `podman-docker` was removed and Docker installed. This run exposed the leftover `/run/docker.sock` link to Podman's socket. After the fix, the next run removed the link, restarted Docker and brought the stack up.
- On Debian, `update` and `status` worked with the `--type container` inspects.

A seventh round checked the fifth review's fixes:

- On Debian with the Compose plugin removed, `install --codename nosuchsuite` failed at Docker's repo ("does not have a Release file"). The script removed `docker.sources` again, and `apt-get update` worked afterwards. A plain `install` then reinstalled the plugin.
- On Fedora and Arch, which already had Docker, a re-run of `install` skipped distribution detection and showed the `LATEST` world warning.

An eighth round checked the sixth review's fixes:

- On Debian, with the Compose plugin removed and a leftover `docker.list` using the same `docker.asc` key, apt printed only "configured multiple times" warnings and the install went through.
- On Fedora and Arch, `update --version latest` (lower case) showed the world warning, and the new `data/` guard let each stack's own world through.
- On the laptop, dry runs refused a foreign non-empty `data/` but accepted an empty one and this script's own, and a preview with no tokens and no terminal worked.
- The non-systemd restart and the `docker info` retry weren't run, because no OpenRC or SysV VM was built.

An eleventh round checked the last review's fixes on Debian. A test wrapper made the second `apt-get update` hang, then SIGTERM went to the script's whole process group, as Ctrl-C does in a terminal. The cleanup trap put `docker.sources` back from the half-applied `bookworm` to `trixie`, left no backup copy in `/tmp`, and the script exited. The same review's other fixes were checked only by lint and dry runs:

- non-systemd `service`/`rc-service` starts that tolerate an already-running Docker;
- refusing rpm-ostree hosts;
- the `check_memory` guard and the cap on `--memory` digits;
- the `sh` prefix in the root hint for a non-executable copy.

Previewing which dependents `--replace-conflicts` removes was left out on purpose: the flag is an explicit opt-in, and this doc says it uses the package manager's normal remove.

A tenth round checked the final review's fixes:

- On all three VMs, `update` took the existing stacks through the new `ip_range` network: Fedora and Arch logged the take-down and rebuild. In every case the network became `172.30.0.0/24` with range `172.30.0.128/25`, Minecraft kept `172.30.0.10`, and the Connector moved to `172.30.0.129`.
- On Debian, with a working `docker.sources` already there, `install --codename nosuchsuite` failed at `apt-get update`. The file was restored byte for byte (same SHA-256, `Suites: trixie`), no backup copy was left behind, and apt worked afterwards.

A ninth round checked the medium-effort review's fixes:

- On Fedora with `moby-engine`, `--dry-run` warned about the conflict instead of stopping and still wrote its preview. `install --replace-conflicts` ran `dnf install --downloadonly --allowerasing` first, then removed `moby-engine docker-cli docker-buildx`, then installed `docker-ce` from the downloaded packages ("Already downloaded"), and Minecraft reached `Done`.
- On Debian, the `--download-only` step ran before the plugin reinstall. `update` with `docker.service` and `docker.socket` stopped brought the daemon back up and the stack with it.
- `update --subnet 10.50.0.0/24` on a running stack worked without any extra step: Compose 5.8 recreated the network, and the server came back on `10.50.0.10`.

The first VM round also caught a real bug: Fedora 45 dropped `PLATFORM_ID`, which the script originally required.

**Not yet tested:**

- A Connector with real tokens. The `State: Online` success path is inferred from the state names the Connector logs, not observed.
- Players joining through the Twingate Client.
- Ubuntu, EL and the derivatives, which were checked only by dry run.
- Non-systemd hosts (OpenRC, SysV, WSL without systemd), rpm-ostree hosts and Raspberry Pi hardware.
- Code review was run 9 times (6 at high effort, 3 at medium), with skeptic agents verifying the first round. The last pass's findings are fixed; no further pass was run after them.
