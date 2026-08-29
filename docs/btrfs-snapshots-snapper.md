# Btrfs Snapshots via Snapper on asus-vivobook

Status: **Working and verified on `asus-vivobook` 2026-08-28.** `snapper` installed, `root` config created with `ALLOW_USERS="kartik"`, all three timers active, apt pre/post hook confirmed firing on a real apt operation, non-root `snapper create`/`list` independently verified.

## Why Snapper, not Timeshift

Kartik asked for Timeshift first. Checking the actual on-disk layout against Timeshift's own docs ruled it out:

| Fact | Value |
|---|---|
| Root filesystem | Btrfs, single partition `/dev/nvme0n1p2` |
| Root subvolume name | `@rootfs` (Debian installer's own convention) |
| Separate `@home` subvolume | None — `/home` lives inside `@rootfs` |

Timeshift's Btrfs mode only supports "Ubuntu-type" layouts with subvolumes named exactly `@` and `@home` (upstream README: *"non-standard BTRFS layouts remain unsupported"*). Making Timeshift work here would mean renaming `@rootfs`→`@` and carving out a real `@home` subvolume — a structural change to a live system that also has VFIO passthrough GRUB cmdline params baked in ([[vfio-4060-passthrough]]). Kartik chose Snapper instead: it snapshots whatever Btrfs layout already exists, no renaming required.

## What gets installed

`snapper` 0.10.6-1.3, from Debian forky's own repos (`sudo apt install snapper` — no third-party download needed, unlike `topgrade`).

The Debian package ships two pieces of automation for free, already on disk before any configuration:

- **`/etc/apt/apt.conf.d/80snapper`** — a `DPkg::Pre-Invoke`/`Post-Invoke` apt hook that creates a *pre* snapshot before and a *post* snapshot after every dpkg-invoking apt operation (install/upgrade/remove), then runs `snapper cleanup number`. This is exactly the "snapshot before a big update" practice the topgrade article recommended — it now happens automatically on every `apt dist-upgrade`, including the one `topgrade` runs, with no change needed to `~/.config/topgrade.toml`.
- **`snapper-boot.service`** — takes one snapshot per boot, tagged `"boot"`.

Both are hardcoded to a config literally named **`root`** (`ConditionPathExists=/etc/snapper/configs/root` for the boot unit; the apt hook checks the same path). The config created below must use that exact name or none of this fires.

## Setup

```bash
bash scripts/setup-snapper.sh
```

The script (idempotent, safe to re-run):

1. `sudo apt install -y snapper`
2. `sudo snapper -c root create-config /` — creates `/etc/snapper/configs/root` and a nested `/.snapshots` subvolume that stores the snapshot data.
3. Sets `ALLOW_USERS="kartik"` and `SYNC_ACL="yes"` in that config, so Kartik can run `snapper create`/`list`/`diff` day-to-day without `sudo` — the privileged Btrfs work is delegated to the root-owned `snapperd` D-Bus service, which checks `ALLOW_USERS` itself.
4. Enables and starts `snapper-timeline.timer`, `snapper-cleanup.timer`, `snapper-boot.timer`.
5. Restarts `snapperd.service` — the package's postinst enables/starts it *before* step 2 creates the config, so it comes up with nothing loaded and every non-root `snapper` call fails with `"No permissions."` until it's restarted, even though the config on disk is already correct. Hit this for real on the first run; the script now handles it.
6. Prints the resulting config, timer state, and creates one test snapshot **as the real invoking user** (via `sudo -u`, not just `snapper create` bare) to confirm the non-root permission actually took effect — a check run as root would trivially pass regardless, since root always bypasses `ALLOW_USERS`.

Everything else is left at the packaged defaults (`TIMELINE_LIMIT_HOURLY=10`, `_DAILY=10`, `_MONTHLY=10`, `_YEARLY=10`, `NUMBER_LIMIT=50`) — sane out of the box, and 408G free on this disk at time of writing leaves plenty of headroom.

## Usage cheat-sheet

```bash
snapper -c root list                          # show all snapshots
snapper -c root create --description "note"   # manual snapshot
snapper -c root diff <n1>..<n2>               # what changed between two snapshots
snapper -c root status <n1>..<n2>              # summarized change list
snapper -c root undochange <n1>..<n2> <path>  # revert specific files, not the whole subvolume
sudo snapper -c root rollback <n>             # set snapshot <n> as the new default subvolume (needs a reboot to take effect)
```

## Caveat: rollback affects `/home` too

Same tradeoff Timeshift would have had: because `/home` isn't a separate subvolume, `snapper rollback` reverts the *entire* `@rootfs` tree, home directory included. For "undo a bad system change" use `undochange` on specific paths instead of a full `rollback` whenever possible. There's no `grub-btrfs` package in Debian, so there's no boot-menu snapshot browsing — recovery is either `snapper rollback` + reboot from a running system, or mounting a snapshot manually from a live USB if the system won't boot at all.

## Not installed

- `snapper-gui` / `btrfs-assistant` — GUI front-ends, not installed since the CLI covers current needs. `btrfs-assistant` is worth a look later if browsing/restoring individual files via a GUI becomes useful.
- `libpam-snapper` — PAM-triggered snapshots on login/logout, not requested.
