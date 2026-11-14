# GParted Ignoring the Desktop Theme (root has no GTK config)

Status: **Fixed on `asus-vivobook` 2026-09-03** with symlinks from root's GTK config to `kartik`'s.
A script audit on **2026-11-14** (finding SYS-1) found those symlinks let any code running as
`kartik` choose a GTK module for root to load. `scripts/sync-root-gtk-theme.sh` was redesigned the
same day and then simplified: it writes **root-owned, filtered copies of the appearance settings**
(reading them with `kartik`'s own privileges) and **copies nothing else** — themes, icon themes and
cursor themes are not copied, only noted for system-wide install (see "Current fix" below). It was run once as root on `asus-vivobook` on 2026-11-14 (see "Re-applying after the
2026-11-14 change"): `--check` first found all three settings files missing from `/root` and no
legacy theme links, `--apply` wrote the filtered copies (leaving out `gtk-modules`, the cursor-blink
and sound-theme keys), and a second `--check` reported all three `ok`. GParted's look hasn't been
checked yet, and `dell-optiplex` still needs its own run.

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

## Second fix (2026-09-03 to 2026-11-14): symlinks, and why they were dropped

The second fix symlinked `/root/.gtkrc-2.0`, `/root/.config/gtk-3.0/settings.ini`,
`/root/.config/gtk-4.0/settings.ini`, `/root/.local/share/themes` and (from 2026-09-24)
`/root/.themes` to the matching paths in `/home/kartik`. Root's config *was* `kartik`'s config, so
it never drifted.

That also meant every file root's GTK reads for its config was writable by `kartik`, and so by
any program running as `kartik`. GTK loads the shared libraries named in the `gtk-modules` setting,
and an absolute path is loaded directly. A program running as `kartik` could add
`gtk-modules=/home/kartik/x.so` to `~/.config/gtk-3.0/settings.ini`, and the next root GParted
(polkit `allow_gui`, X11 backend) would `dlopen()` it as root. This was reproduced on 2026-11-14
without root. `HOME` pointed at a scratch "root" directory holding the old script's symlinks, and
`GDK_BACKEND=x11 gtk-query-settings gtk-modules` ran the constructor of a test library named only
in the user-side file. The theme directories had the same problem. A GTK 3 theme's own
`gtk-3.0/settings.ini` is read like the user's: the same test, with the module named only in a
user-local theme's `settings.ini`, loaded it on X11. GTK 2 rc files can also name a theme engine
by absolute path.

A first version of the copy approach (2026-11-14, morning) tried to copy the theme trees too and
scan each theme for anything dangerous before copying it. A GTK theme is a large set of GTK 2 rc
files and GTK 3 CSS with many ways to name a module or pull in another file (a `settings.ini`
reached through an in-theme symlink, an `include` of an arbitrary extensionless file, a CSS
`@import`, escapes that hide a separator), and successive reviews kept finding ways past the
scanner. Vetting a user-writable theme well enough to hand to root was abandoned.

## Current fix (2026-11-14): filtered settings copies only, nothing else copied

The earlier copy-based version (which also handed root copies of the theme and icon trees) was
simplified away. A GTK theme is a large user-writable tree, and vetting one well enough to hand to
root proved unreliable: six review passes each found a new root-side bug in the copy machinery —
loading a module named in a theme, deleting `kartik`'s directory through a symlinked `/root`
ancestor, writing a marker through a planted symlink into `/etc`, a lexical link rule defeated by a
newline, and more. So **root no longer copies anything from `kartik`'s home.** The only thing it
writes is a filtered copy of the appearance *settings*; themes, icon themes and cursor themes stay
where they are, and GTK uses them only if they're installed system-wide.

`scripts/sync-root-gtk-theme.sh --apply` runs as root and:

- **Reads every settings file as `kartik`, never as root.** The user is the one who invoked
  `pkexec` or `sudo` (`PKEXEC_UID`, then `SUDO_UID`), looked up in the passwd database, and their
  home is that passwd entry's home (so a user whose home isn't `/home/kartik` works, even though
  `pkexec` drops the environment); the script refuses to run if neither is set or if it's uid 0.
  `KARTIK_HOME`/`ROOT_HOME` overrides count only with the test flag `SYNC_ROOT_GTK_TEST_HOME=1`,
  which prints a loud `TEST MODE` warning. Each read goes through `setpriv` with that user's uid, gid and groups — a real drop, never
  a read as root. So a symlink swapped in under `kartik`'s config, even after the script's own
  checks, can only ever expose a file `kartik` can already read, never `/root`.
- **Settings files** (`~/.gtkrc-2.0`, both `settings.ini`) are filtered to an allowlist of
  appearance keys: theme, icon theme, cursor theme and size, font, prefer-dark, the `gtk-xft-*`
  font-rendering keys, decoration layout, animations, button/menu images and toolbar style. A value
  is kept only if it has no path characters (`/`, `~`, `..`, quotes, `$`). Everything else is left
  out, including `gtk-modules`, `gtk-im-module`, and the GTK 2 statements `include`, `module_path`,
  `im_module_file`, `pixmap_path` and whole `style`/`engine` blocks. Each is written to a temp file
  in the destination directory, set to `0644 root:root`, and renamed into place with `mv -T`; a
  leftover symlink there is replaced, never written through. The source must also resolve inside `~`
  and be owned by `kartik`, or it's skipped (defense in depth on top of the as-`kartik` read).
- **Themes, icon themes and cursor themes are NOT copied.** `~/.themes`, `~/.local/share/themes`,
  `~/.icons` and `~/.local/share/icons` are left alone. Root's settings still name them; GTK uses
  them only if they're installed system-wide (`/usr/share` or `/usr/local/share`), else it falls
  back to the default — no code or data from a user-writable tree is handed to root. When a
  configured `gtk-theme-name`, `gtk-icon-theme-name` or `gtk-cursor-theme-name` is found only under
  `kartik`'s user-local dirs, `--apply` and `--check` print a `NOTE` (not a failure) naming it and
  its source path (`printf %q`-quoted), and **no root command**. Root can't safely use a tree
  `kartik` can write: reading it in place hands him what root loads, and an automated copy installs
  whatever the tree holds at that moment, links included (an earlier version printed a
  `tar … | pkexec tar …` command, and even with a link check it could install a link back into
  `~` or a tree changed between check and copy). Install it system-wide by a route you trust — the
  distro or AUR package if one exists, or a manual copy into `/usr/local/share/themes` or
  `/usr/local/share/icons` that you have reviewed.
- **Guards.** If a directory between `/root` and a settings target is a symlink, `--apply` refuses
  rather than writing through it. Anything at a target that the script didn't write (its files carry
  a managed header line) is backed up to `*.bak-<epoch>` first.
- **Legacy `/root` directories.** Older versions created `/root/.themes` and
  `/root/.local/share/themes` (symlink era), and could have created `/root/.icons` and
  `/root/.local/share/icons` (copy era). A leftover would keep root GTK reading user-controlled
  data. The two theme paths are handled whatever is there. The two icon paths are often root's own
  (e.g. `/root/.icons/default/index.theme` setting root's cursor), so they are handled **only** when
  the path is a symlink into `kartik`'s home (by its own target or where it finally resolves) or a
  directory carrying the copy era's `.sync-root-gtk-theme` marker; any other real root icon
  directory is left alone and not reported. One shared classifier drives both `--check` and `--apply`, and the cleanup **never
  recursively deletes anything** (a `rm -rf` on a `/root` path whose ancestor is a symlink would
  delete `kartik`'s own directory through the link). A path that is itself a symlink has only the
  link removed (`rm -f`, which never touches the target). A path with a symlinked ancestor (a
  directory above it under `/root` that is a symlink, which could reach into `kartik`'s home) is
  always left untouched and reported `UNSAFE`, naming the ancestor; `--apply` refuses and tells
  `kartik` to remove that ancestor by hand. A real directory, whatever it holds, is renamed aside
  with `mv -T` to `*.bak-<epoch>` (a rename can't recurse) and reported `LEGACY` — never deleted.

The copies go under `/root` because only root should see them and `/root` is mode `0700`.
Copies don't follow `kartik`'s later edits, so re-run `--apply` after a theme switch (KDE System
Settings, or the script's own `--set`/`--pick`, which print the command). `--check` diffs the
filtered settings it would write against what's in `/root`, reporting `DRIFT` on any difference,
`UNSAFE` for a symlink or a non-root-owned/world-writable file, `STALE` for a copy whose source is
gone, `UNSAFE`/`LEGACY` for a leftover `/root` directory, and `NOTE` for a user-local-only theme.
A change to a key that is never copied, such as `gtk-modules`, is not drift.

`--set` and `--pick` rewrite the invoking user's own GTK config, so they refuse to run as root
(use `--apply` for root), and they follow a symlinked dotfile only when it resolves inside that
user's home and is theirs — never out to a file like `/etc/sudoers`. They validate all three
settings files first and change nothing if any present one is unsafe, then write each and report
it, so the three can't end up disagreeing after a mid-way abort. Every path printed in a `NOTE`
or inside the one copy-pasteable command (the trust-install hint) is quoted with `printf %q`, and a
theme name with a slash or control character is skipped, so a crafted name can't become a command
when pasted.

```bash
pkexec /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh --check
pkexec /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh --apply
```

`pkexec` needs the absolute path. Started as `kartik` without `pkexec`, the script re-runs itself
under `sudo` instead.

**Trust.** The root path executes only the script file itself; `scripts/lib/tui.sh` is sourced
solely by `--pick`, which runs as `kartik`. But the repo copy is writable by `kartik`, so running
it through `pkexec` trusts `kartik`'s account with root: whoever can edit the file before the next
`pkexec` run controls what runs as root. That's inherent to running a script from a user's
checkout, not something the script can check its way out of, so it doesn't refuse (that would
block the route above). It prints a `WARNING` whenever the file, or a directory on its path, can
be changed by a non-root user. To get rid of the trust and the warning, install a root-owned copy
and run that instead (re-install after changing the repo copy):

```bash
pkexec install -m 0755 -o root -g root \
  /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh \
  /usr/local/sbin/sync-root-gtk-theme
pkexec /usr/local/sbin/sync-root-gtk-theme --apply
```

The installed copy doesn't need `scripts/lib/`; only `--pick` does, and it reports the lib as
missing if it isn't beside the script.

### What a run on this host would leave out

From the settings files, `--apply` filters out `gtk-modules=colorreload-gtk-module` (KDE's live
colour-reload module, which root GParted doesn't need), the cursor-blink keys,
`gtk-primary-button-warps-slider` and `gtk-sound-theme-name`. Kartik's GTK theme (Nordic) and icon
theme (Papirus-Dark) are installed system-wide under `/usr/share`, so neither gets a `NOTE`. His
`Nordic-cursors` cursor theme is user-local under `~/.icons`, so a `NOTE` says root GParted falls
back to the default cursor until he installs it system-wide himself (a package, or a reviewed
copy into `/usr/local/share/icons`).

### Not covered: XSETTINGS

On X11, a root GTK app also takes settings from the XSETTINGS manager of the display it opens. On
KDE that's `xsettingsd`, running as `kartik` from `~/.config/xsettingsd/xsettingsd.conf`, which
`kartik` owns. In the 2026-11-14 tests, `gtk-query-settings` with `HOME` pointed at the scratch
root copy still reported the live session's `Nordic` theme, which came from XSETTINGS.
`libgdk-3.so` contains the XSETTINGS name `Gtk/Modules` next to `Gtk/IMModule`, which suggests GDK
also maps it to `gtk-modules`. If so, code that can act as the session's XSETTINGS manager could
still name a module for a root GTK app on the same display. That wasn't reproduced. No file under
`/root` can close it. The only way to avoid it is to not run root GTK apps on `kartik`'s display:
use `parted`/`sfdisk` from a root shell, or a partition editor whose GUI runs unprivileged and
hands only the disk work to a root helper.

## Verification

- **2026-09-03 (symlink version):** `--check` reported `ok`, and Kartik confirmed GParted rendered
  themed.
- **2026-11-14 (this design), scratch directories only.** Tested in a user namespace with two uid
  ranges (my uid mapped to root, my subuids to the rest), so inner uid 1000 is a real, distinct
  `kartik` and `setpriv` genuinely drops to it; a root-owned `0600` file in `kartik`'s tree really
  is unreadable to it. The copy-based design was taken apart and re-checked over several review
  passes before being dropped — those passes reproduced and fixed a module loaded from a copied
  theme, a marker written through a planted symlink into a victim file, `kartik`'s directory deleted
  through a symlinked `/root` ancestor, and a newline-truncated link rule. The current settings-only
  script is verified here: `--apply` writes `0644 root:root` settings files with `gtk-modules` and
  every non-appearance key dropped, and `GDK_BACKEND=x11 gtk-query-settings gtk-modules` against the
  copy reports `gtk-modules: NULL` (the same query loaded a test module through the original
  symlinks). A settings source symlinked outside `~` is skipped with nothing reaching `/root`. The
  script refuses without `PKEXEC_UID`/`SUDO_UID` and refuses uid 0; a user whose passwd home isn't
  `/home/kartik` works with no overrides, and a stray `KARTIK_HOME` is ignored outside test mode. `--set`/`--pick` refuse as root and validate all three files before
  writing any (one out-of-home target changes nothing). The legacy cleanup never recurses: a
  `/root/.themes` symlink, or a `/root/.icons` symlink into `~`, is unlinked; a `/root/.local`
  symlinked ancestor is refused with `kartik`'s dir untouched; a real `/root/.themes` or a marked
  `/root/.icons` is renamed to `*.bak-<epoch>`, never deleted; a real, unmarked
  `/root/.icons/default` is left alone and unreported. The `NOTE` for a user-local
  theme/icon/cursor prints no root command in any case (symlinked tree, in-tree absolute link,
  escaping link, clean tree). The Brother script exits `0`/`1`/`2` (verified/failed/
  unverified). `scripts/lib/tui.sh` is sourced only by `--pick` (guarded by
  `scripts/test_tui_lib.py`), and the root-path `WARNING` fires only for a non-root-writable script.
- **Not verified:** GParted's look after the new `--apply`, and `dell-optiplex`'s `/root`. On `asus-vivobook`, `/root` was checked and applied as root on 2026-11-14 (see the status at the top).

## Re-applying after the 2026-11-14 change

Run `--apply` once as root to replace whatever the old version left. Then check that `--check`
reports no `UNSAFE` line, and relaunch GParted:

```bash
pkexec /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh --apply
pkexec /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh --check
```

Both print the repo-copy trust `WARNING` described under "Trust" above. To avoid it, install the
root-owned copy first and run `pkexec /usr/local/sbin/sync-root-gtk-theme --apply` /
`--check` instead.

After that, re-run `--apply` whenever GParted (or another root-elevated GTK app) looks unthemed,
or after a theme switch. `--check` shows whether that's needed.

## `dell-optiplex` (Cinnamon) — 2026-09-24

Written against the symlink version, so this host also needs the new `--apply` once.

Nordic (from `EliverLara/Nordic` `master`) is installed user-locally in `~/.themes`, the legacy
path Nordic's own README uses, which the script didn't link at the time. It then also symlinked
`/root/.themes` → `/home/kartik/.themes`. The current script does not copy or link GTK themes at
all, and treats that `/root/.themes` symlink as a legacy path to clean up: `--apply` removes it (as
above), and the `NOTE` explains that Nordic must be installed system-wide — from a package if the
distro has one, or as a reviewed copy into `/usr/local/share/themes` — for root GParted to use it. Cinnamon
themes through XSETTINGS rather than `settings.ini`, which a `pkexec`-launched GParted still reads
over X, so the two `settings.ini` sources don't exist on this host. `--check` reports those as
`skip` rather than `DRIFT`. `sudo` has no TTY from a Claude Code shell, so the script was run
whole as root in one call: `pkexec bash -c 'scripts/sync-root-gtk-theme.sh'` (absolute path).
GParted confirmed themed by Kartik the same day (with the old symlink version; the new one needs
re-running once, which also removes that `/root/.themes` link).

## Applies to other root-elevated GUI apps too

Any GTK app on this host that self-elevates via `pkexec`/`gksu`/bare `su` (not `sudo -E` or
`sudo --preserve-env`) reads root's GTK config, so root's copies cover future GUI apps (a disk
utility, a package manager GUI, and so on) too. If one still shows up unthemed, check whether it
uses a *different* config mechanism (e.g. a Qt app reading `kdeglobals`, not GTK) before assuming
this fix regressed.
