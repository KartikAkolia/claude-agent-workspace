# GParted Ignoring the Desktop Theme (root has no GTK config)

Status: **Fixed and confirmed on `asus-vivobook` 2026-09-03**, then **recurred the same day** when
Kartik switched his theme, and **fixed durably via symlinks** later the same day. GParted now
opens themed (currently catppuccin-mocha-mauve-standard+default / Papirus-Dark /
Capitaine-Cursors-White) instead of falling back to stock Adwaita, and will keep following
whatever theme Kartik switches to next without needing this fix reapplied.

## Symptom

Kartik's desktop is themed (see [`lightdm-nordic-theme-setup.md`](lightdm-nordic-theme-setup.md)),
but GParted opened with the default GTK theme regardless.

## Root cause

GParted has to run as root to touch partitions. `/usr/sbin/gparted` is a wrapper script; when
launched as a normal user it re-execs itself via:

```sh
pkexec --disable-internal-agent '/usr/sbin/gparted' "$@"
```

`pkexec` runs the target as **root** and, by design, does not inherit the calling user's
environment or `$HOME`. The re-launched GTK process therefore reads *root's* GTK config — not
`kartik`'s `~/.config/gtk-3.0/settings.ini` / `~/.gtkrc-2.0` — and root had no such files, so it
fell back to the default theme.

This is not specific to dwm, lightdm, or this host's theme install: it's how any `pkexec`-launched
(or `sudo`/`su`-launched, minus `-E`) GUI app behaves on any Linux system.

### First fix attempt (2026-09-03, morning) and why it broke again the same day

The initial fix gave root a **static copy** of the config, hardcoding the theme name (at the time,
Nordic — installed system-wide under `/usr/share/themes`, so root could read the files fine once
it knew to look). That worked until Kartik switched his GTK theme to
`catppuccin-mocha-mauve-standard+default` later the same day: root's copy still said `Nordic`, so
GParted reverted to unthemed. Two independent config files drifting apart was the whole problem —
any future theme change would have broken it again.

There was also a second issue the static copy masked: catppuccin isn't installed system-wide, only
under `kartik`'s `~/.local/share/themes/`. Because `pkexec` gives root `$HOME=/root`, root's GTK
theme search path never looks inside `/home/kartik` — so even a correctly-updated static config
wouldn't have found the actual theme files. Icons (Papirus-Dark) and cursor
(Capitaine-Cursors-White) stayed system-wide under `/usr/share/icons` throughout, so only the GTK
*theme* was ever affected by this second issue.

## Fix (durable — symlinks, not copies)

Symlink root's GTK config to `kartik`'s config, and symlink root's local theme directory to
`kartik`'s, so both the settings and the theme files themselves stay in sync automatically.

`scripts/sync-root-gtk-theme.sh` does this and is the current, maintained way to (re)apply it —
idempotent, backs up rather than deletes anything real it finds in the way of a symlink, and
distinguishes a genuine sudo-auth failure from an actual drifted path instead of misreporting one
as the other:

```bash
scripts/sync-root-gtk-theme.sh --check   # report drift only, changes nothing
scripts/sync-root-gtk-theme.sh           # (re)apply the symlinks
```

Everything under `/root` is mode `0700`, so the script has to go through `sudo` for every read or
write against it, including plain existence checks — `kartik` can't even `stat` a path under
`/root` otherwise. Run it as `kartik`; it escalates itself per-command and will prompt for a
password interactively.

Root can traverse into `/home/kartik` through the symlinks even though the home directory itself
isn't world-readable — root bypasses normal file permission checks (DAC_OVERRIDE), so this works
regardless of `kartik`'s home directory permissions.

The commands below are what the script runs internally, kept here for reference:

```bash
sudo mkdir -p /root/.config/gtk-3.0 /root/.config/gtk-4.0 /root/.local/share

sudo rm -f /root/.gtkrc-2.0
sudo ln -s /home/kartik/.gtkrc-2.0 /root/.gtkrc-2.0

sudo rm -f /root/.config/gtk-3.0/settings.ini
sudo ln -s /home/kartik/.config/gtk-3.0/settings.ini /root/.config/gtk-3.0/settings.ini

sudo rm -f /root/.config/gtk-4.0/settings.ini
sudo ln -s /home/kartik/.config/gtk-4.0/settings.ini /root/.config/gtk-4.0/settings.ini

if [ -e /root/.local/share/themes ] && [ ! -L /root/.local/share/themes ]; then
  sudo mv /root/.local/share/themes "/root/.local/share/themes.bak-$(date +%s)"
fi
sudo ln -sfn /home/kartik/.local/share/themes /root/.local/share/themes
```

No reboot or logout needed — GParted (or any other `pkexec`-elevated GTK app) picks it up on next
launch.

## Verification

- `scripts/sync-root-gtk-theme.sh --check` reports `ok` for all four paths.
- Relaunched GParted — window chrome, icons, and cursor all render themed.
- Confirmed by Kartik 2026-09-03: the symlink fix itself (after the static-copy fix from earlier
  the same day had drifted out of sync), and again after `sync-root-gtk-theme.sh` was written to
  wrap it — `--check` showed all four already `ok`, no drift.

## Re-checking or re-applying later

Run `scripts/sync-root-gtk-theme.sh --check` any time GParted (or another root-elevated GTK app)
looks unthemed again, or just to confirm nothing has drifted after a theme switch. It shouldn't
need to report drift going forward — that's the point of symlinking over copying — but if it ever
does, plain `scripts/sync-root-gtk-theme.sh` re-applies it without needing this doc's commands
copy-pasted by hand again.

## Applies to other root-elevated GUI apps too

Any GTK app on this host that self-elevates via `pkexec`/`gksu`/bare `su` (not `sudo -E` or
`sudo --preserve-env`) reads root's GTK config, which is now symlinked to `kartik`'s — so this
should already cover future GUI apps (a disk utility, package manager GUI, etc.) without needing
this fix reapplied. If one still shows up unthemed, check whether it uses a *different* config
mechanism (e.g. a Qt app reading `kdeglobals`, not GTK) before assuming this fix regressed.
