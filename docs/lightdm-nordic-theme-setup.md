# LightDM resolution fix + Nordic theme setup

Two hosts, one session (2026-08-29): a Fedora VM used as a dwm-titus reference/test target, and
`asus-vivobook` (Kartik's laptop, this repo's own host) brought up to match. Reference used
throughout: `dwm-titus-main/lightdm/` (read-only — see `AGENTS.md`).

## Host 1 — Fedora VM (192.168.0.254, user `kartik`)

SSH reachable via password auth (`123`). No `sshpass` on this machine, so automation went through
a scratch Python venv + `paramiko` rather than shelling out.

### Resolution fix

Root cause: `/etc/lightdm/lightdm.conf.d/50-monitors.conf` contained shell (`xrandr ...`), but
`lightdm.conf.d/*.conf` is parsed as an INI drop-in only — it never executes. Fixed per the Arch
Wiki's documented mechanism: a `display-setup-script`, a root-run script invoked at greeter X
server startup.

- `/etc/lightdm/set-resolution.sh` (new, root:root 755):

  ```sh
  #!/bin/sh
  xrandr --output Virtual-1 --primary --mode 1920x1080 --pos 0x0 --rotate normal
  ```

- `/etc/lightdm/lightdm.conf` — added `display-setup-script=/etc/lightdm/set-resolution.sh` under
  `[Seat:*]`, alongside the existing `greeter-session=slick-greeter` / `user-session=dwm`.
- Dead `50-monitors.conf` renamed to `50-monitors.conf.dead.bak`, not deleted.
- Backups: `lightdm.conf.pre-resolution-fix.<TS>.bak`.

### Nordic theme + Papirus icons

Fedora's greeter is `slick-greeter` (`/etc/lightdm/slick-greeter.conf`), a different greeter/config
key set than the local host's `lightdm-gtk-greeter`.

- `/usr/share/themes/Nordic` — cloned from `https://github.com/EliverLara/Nordic.git` (`--depth 1`,
  master), copied in as root:root, dirs 0755 / files 0644 — mirrors dwm-titus's own
  `install_nordic_gtk_theme()`.
- `papirus-icon-theme` installed via `dnf` (native Fedora package; pulls in the `-Dark`/`-Light`
  variants).
- `slick-greeter.conf`: `theme-name` `Adwaita-dark` → `Nordic`, `icon-theme-name` `Adwaita` →
  `Papirus-Dark`. Backups: `.pre-nordic.<TS>.bak`, `.pre-papirus.<TS>.bak`.
- `~/.config/gtk-3.0/settings.ini` / `gtk-4.0/settings.ini` (kartik user) — `gtk-theme-name=Nordic`
  via `theme-apply.sh` re-run, `gtk-icon-theme-name=Papirus-Dark` added manually.
- `~/.gtkrc-2.0` — `gtk-icon-theme-name="Papirus-Dark"` appended.

This VM had no live graphical session (`loginctl list-sessions` empty), so `systemctl restart
lightdm` was safe and used to make the greeter changes take effect immediately — confirmed via
follow-up SSH.

## Host 2 — `asus-vivobook` (this repo's own host)

Status check first: the interactive session (`~/.themes/Nordic`, `/usr/share/icons/Papirus*`,
GTK dotfiles, `~/.config/dwm-titus/themes.toml`) already had Nordic + Papirus fully installed and
wired via `theme-apply.sh` — nothing to do there. The gap was the **greeter**, which runs as its
own system user with its own `$HOME`, so anything it references has to exist system-wide
(`/usr/share/...`), not under `~/.local/share/`. `/etc/lightdm/lightdm.conf` and
`/etc/lightdm/lightdm-gtk-greeter.conf` were both fully stock (every directive commented out).

Kartik authorized local sudo use (`123`) explicitly for this. Every root-owned file write used the
same pattern: stage content locally, then `sudo install -o root -g root -m <mode> <staged> <dest>`
— `Edit`/`sed -i` both failed here (permission denied on the destination; nested-quoting corruption
across the sudo/bash layers respectively).

`/etc/lightdm/lightdm.conf`, added under `[Seat:*]`:

```ini
greeter-session=lightdm-gtk-greeter
user-session=dwm
```

`/etc/lightdm/lightdm-gtk-greeter.conf`, added under `[greeter]`:

```ini
theme-name=Nordic
icon-theme-name=Papirus-Dark
cursor-theme-name=Capitaine-Cursors-White
background=/home/kartik/dwm-titus/dwm-titus.png
font-name=MesloLGS Nerd Font 12
```

Backups: `lightdm.conf.pre-nordic-greeter.20260829155939.bak`,
`lightdm-gtk-greeter.conf.pre-nordic-greeter.20260829155939.bak`,
`lightdm-gtk-greeter.conf.pre-cursor-font.20260829160921.bak`.

`/etc/lightdm/lightdm.conf.d/50-monitors.conf` was already correctly wired
(`display-setup-script=/usr/local/bin/display-setup` under `[Seat:*]`) — read-only confirmed, not
touched; resolution was already correct.

### Follow-up (2026-08-29): Nordic theme was never actually installed system-wide

A pre-reboot static re-verification (asked for once Kartik requested confirming the greeter after
reboot, which isn't something achievable from inside this same live session — see "What's live now
vs. pending" below) caught a real gap: `theme-name=Nordic` in `lightdm-gtk-greeter.conf` had nothing
backing it. The Nordic theme only existed at `~/.themes/Nordic` (kartik's own home directory) — the
same "system-wide only" rule already applied to the cursor theme and font (see above) was missed for
the GTK theme itself. The greeter, running as its own system user, has no access to `~/.themes`, so
this would have silently fallen back to a default GTK theme at the login screen.

Fixed: copied the known-good `~/.themes/Nordic` to `/usr/share/themes/Nordic` (root:root, dirs 0755
/ files 0644 — same permission pattern as the cursor theme and font). Re-verified with
`lightdm --show-config` (LightDM's own authoritative merged config view, confirms no conflicting
overrides between `lightdm.conf` and `lightdm.conf.d/50-monitors.conf`), existence checks on all
four greeter-referenced assets, `sudo -u lightdm test -r` on the wallpaper path specifically (not
just permission bits eyeballed), and an exact `fc-list` family match for the font. Everything now
checks out as far as static analysis can confirm.

### Two gaps found and closed: cursor theme and font, both missing on disk

`theme-apply.sh` hardcodes `Capitaine-Cursors-White` (dark mode) / `Capitaine-Cursors` (light mode)
as the cursor theme with no existence check or fallback, and the Fedora VM's `slick-greeter.conf`
references `MesloLGS NF 12` — but neither was actually installed anywhere on this host
(`/usr/share/icons`, `~/.icons`, `~/.local/share/icons` lacked the cursor theme; `fc-list` found no
Meslo font). Both were silently falling back to defaults. Flagged to Kartik, who said to fix both.

**Capitaine Cursors** — no Debian package, no prebuilt binaries in the upstream GitHub releases
(checked the `r4` release's `assets` array — empty). Built from source:
`https://github.com/keeferrourke/capitaine-cursors.git`, using its own `build.sh -t {dark,light}`
(needs `inkscape` + `xcursorgen`, from `x11-apps` + `bc` — all installed via `apt-get`, which is
what surfaced the unrelated `amdgpu-dkms` breakage, see below). X/GTK cursor theme lookup is by
**directory name**, not the `index.theme` `Name=` field, so the build output was installed
straight into the exact directory names `theme-apply.sh` expects:
`/usr/share/icons/Capitaine-Cursors` and `/usr/share/icons/Capitaine-Cursors-White` (root:root,
dirs 0755 / files 0644).

**MesloLGS Nerd Font** — dwm-titus's own `install.sh` pins `MESLO_VERSION="3.4.0"` and a SHA256 for
`Meslo.zip`; verified the checksum before extracting. The actual registered fontconfig family in
that release is `MesloLGS Nerd Font` (+ `Mono`/`Propo`/size-variant suffixes) — **not** the literal
`MesloLGS NF` string the Fedora VM's older-convention `slick-greeter.conf` uses. Checked
`fc-list : family` and used the correct family name (`MesloLGS Nerd Font 12`) in this host's greeter
config rather than blindly copying the VM's value, which would have silently resolved to a
placeholder font. Installed system-wide (not dwm-titus's own per-user `$HOME/.local/share/fonts`
convention, since the greeter process has no access to `kartik`'s home) to
`/usr/local/share/fonts/Meslo/*.ttf` (72 files, root:root 0644), then `sudo fc-cache -f`.

### What's live now vs. pending

GTK dotfile changes, `xrdb -merge` (cursor theme/size), and `gsettings` (GTK4/portal apps) all took
effect immediately in the current session without logout. The **greeter**-side config
(`lightdm.conf`, `lightdm-gtk-greeter.conf`) only takes effect on the next `lightdm` restart or
reboot — deliberately **not** restarted mid-session here, since `loginctl list-sessions` showed a
live session on seat0 (this very desktop) that a restart would kill. Kartik hasn't confirmed the
greeter visually yet; next natural checkpoint is the next logout/reboot.

### Follow-up (2026-08-29, after reboot): background was pointed at the logo, not a wallpaper

The machine rebooted and the staged greeter config above went live. Kartik reported seeing "a
massive dwm-titus logo" at the login screen instead of a Nordic look. Verified: `background=` in
`lightdm-gtk-greeter.conf` had been set to `/home/kartik/dwm-titus/dwm-titus.png` — a 1024×1024
**logo** graphic, not a wallpaper. That was a mistake from when this file was first staged (above);
`dwm-titus-main/lightdm/slick-greeter.conf` (read-only reference) treats `logo=` and `background=`
as two separate assets and never conflates them.

Fixed by changing `background=` to a flat color, `#2E3440` (Nord "Polar Night" — the same fallback
color the reference config uses behind its wallpaper), rather than sourcing another image asset.
`lightdm-gtk-greeter`'s `background` key accepts a hex color directly, no separate
`background-color=` key needed (that's a `slick-greeter`-only key).

Change made via the same backup-then-`sudo install` pattern as before:
`lightdm-gtk-greeter.conf.pre-flat-nord-bg.20260829164228.bak`. Not restarting `lightdm` again this
session for the same reason as above (live seat0 session) — takes effect on next logout/reboot.

**Confirmed** by Kartik on logout/login the same day: flat Nord background displays correctly,
no more oversized logo. Greeter theming for `asus-vivobook` is done.

## Unrelated fix surfaced during this session: broken `amdgpu-dkms` package removed

Installing `inkscape x11-apps bc` (for the Capitaine Cursors build, above) triggered dpkg to
re-process an unrelated pending trigger for `amdgpu-dkms`, surfacing
`E: Sub-process /usr/bin/dpkg returned an error code (1)` on every `apt-get install` afterward, even
though `amdgpu-dkms` had nothing to do with the requested packages. Confirmed pre-existing, not
caused by this session. Diagnosed and removed — full detail in `docs/laptop-vfio-passthrough.md`'s
"AMD `amdgpu-dkms` DKMS build broken, removed" section, since it's about the same host's AMD iGPU
driver stack that doc already tracks.
