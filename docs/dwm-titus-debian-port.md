# dwm-titus on Debian (Homelab Host)

Record of porting ChrisTitusTech's `dwm-titus` (Fedora-only upstream) onto Kartik's Debian homelab host at 192.168.0.222. Confirmed working end to end on 2026-08-24: built, installed, themed, and launchable from the display manager.

## Why the upstream installer can't be used as-is

`dwm-titus-main/install.sh` hard-rejects any non-Fedora distro:

```bash
case "$DISTRO_FAMILY" in
fedora)
	command -v dnf &>/dev/null || {
		err "Fedora was detected, but dnf was not found."
		exit 1
	}
	;;
*)
	err "Unsupported distribution: $DISTRO_NAME"
	err "dwm-titus supports Fedora only."
	exit 1
	;;
esac
```

So this was a manual port: apt equivalents for every Fedora package, plus the same non-package install steps (Herdr, Meslo font, Nordic theme, Nord wallpapers) the installer would otherwise run, followed by `make` / `sudo make install` from the dwm-titus source itself, which are distro-agnostic.

## Package mapping (Fedora dnf → Debian apt)

Source of truth for the Fedora side: `dwm-titus-main/scripts/dwm-packages.sh`, which defines a `dwm_packages()` function keyed by profile. Every Debian name below was verified against `packages.debian.org` (suite=unstable/sid, matching the host's actual release) before installing.

**build**

| Fedora | Debian |
|---|---|
| gcc | gcc |
| make | make |
| pkgconf-pkg-config | pkgconf |
| libX11-devel | libx11-dev |
| libXft-devel | libxft-dev |
| libXinerama-devel | libxinerama-dev |
| libXrender-devel | libxrender-dev |
| imlib2-devel | libimlib2-dev |
| libxcb-devel | libxcb1-dev |
| xcb-util-devel | libxcb-util-dev |
| freetype-devel | libfreetype-dev |
| fontconfig-devel | libfontconfig-dev |

The `dwm-packages.sh` build profile turned out to be incomplete relative to what the Makefile's `check-build-deps` target actually checks for via pkg-config. Two more dev packages were required and are not listed anywhere in the Fedora profile: `libx11-xcb-dev` and `libxcb-res0-dev`, providing the `x11-xcb` and `xcb-res` pkg-config modules respectively. Both were needed before `make` would proceed past `check-build-deps`.

**x11**

| Fedora | Debian |
|---|---|
| xorg-x11-server-Xorg | xserver-xorg |
| xorg-x11-xinit | xinit |
| xrandr / xset / xsetroot | x11-xserver-utils (bundles all three) |
| xinput | xinput |
| setxkbmap | x11-xkb-utils |

**runtime-required**

| Fedora | Debian |
|---|---|
| dbus-x11 | dbus-x11 |
| curl | curl |
| git | git |
| procps-ng | procps |
| psmisc | psmisc |
| unzip | unzip |
| util-linux | util-linux |
| xclip | xclip |
| xdotool | xdotool |
| xprop | x11-utils |
| xdg-utils | xdg-utils |

**desktop**

| Fedora | Debian |
|---|---|
| quickshell | quickshell (packaged for Debian sid at 0.3.0-1 — not Fedora-exclusive as first assumed) |
| picom | picom |
| feh | feh |
| dex-autostart | dex |
| mate-polkit | mate-polkit |
| alsa-utils | alsa-utils |
| brightnessctl | brightnessctl |
| pulseaudio-utils | pulseaudio-utils |
| pipewire | pipewire |
| pavucontrol | pavucontrol |
| pipewire-pulseaudio | pipewire-pulse |
| wireplumber | wireplumber |
| libnotify | libnotify-bin |
| light-locker | light-locker |
| xorg-x11-drv-libinput | xserver-xorg-input-libinput |
| bluez | bluez |
| blueman | blueman |
| playerctl | playerctl |

**desktop-optional**

| Fedora | Debian |
|---|---|
| Thunar | thunar |
| gvfs | gvfs |
| gvfs-smb | gvfs-backends |
| tumbler | tumbler |
| thunar-archive-plugin | thunar-archive-plugin |
| file-roller | file-roller |
| xdg-user-dirs | xdg-user-dirs |
| xdg-desktop-portal-gtk | xdg-desktop-portal-gtk |
| gnome-keyring | gnome-keyring |
| gnome-keyring-pam | libpam-gnome-keyring |
| NetworkManager | network-manager |
| rsync | rsync |

**theme**

| Fedora | Debian |
|---|---|
| dconf | dconf-cli |

**theme-gtk**

| Fedora | Debian |
|---|---|
| arc-theme | arc-theme |
| adw-gtk3-theme | **no Debian package exists at all** — confirmed via a zero-result search across every Debian suite, not just a naming difference. Upstream `adw-gtk3` is distributed via Flatpak (`org.gtk.Gtk3theme.adw-gtk3`) or manual GitHub releases only. Skipped on this host. |
| numix-gtk-theme | numix-gtk-theme |
| yaru-gtk3-theme / yaru-gtk4-theme | yaru-theme-gtk (Debian splits Yaru into 5 packages: `yaru-theme-gtk`, `yaru-theme-icon`, `yaru-theme-gnome-shell`, `yaru-theme-sound`, `yaru-theme-unity` — installed the closest match) |
| deepin-gtk-theme | **not available in Debian sid** — no substitute installed; would need a source/manual build |
| bluebird-gtk3-theme | bluebird-gtk-theme (no "3" in the Debian name) |

**theme-optional**

| Fedora | Debian |
|---|---|
| qt6ct | qt6ct |
| qt5ct | qt5ct |

**fonts**

| Fedora | Debian |
|---|---|
| google-noto-color-emoji-fonts | fonts-noto-color-emoji |
| google-noto-sans-mono-fonts | fonts-noto-mono |

**qml-development**

| Fedora | Debian |
|---|---|
| qt6-qtdeclarative-devel | qt6-declarative-dev |

**lightdm**

| Fedora | Debian |
|---|---|
| lightdm | lightdm |
| slick-greeter | slick-greeter (not `lightdm-slick-greeter`) |

**terminal / terminal-primary**

| Fedora | Debian |
|---|---|
| alacritty | alacritty |
| kitty | kitty |

**screenshot-optional**

| Fedora | Debian |
|---|---|
| maim | maim |

**gaming** (x86_64 only, needs 32-bit multiarch enabled — already was on this host via `dpkg --add-architecture i386`)

| Fedora | Debian | Result |
|---|---|---|
| steam | steam-installer (contrib; `steam` is a transitional package pointing to it) | installed |
| gamescope | gamescope | installed (3.16.24+ds-2) |
| gamemode.x86_64 / gamemode.i686 | gamemode + `libgamemode0:i386`/`libgamemodeauto0:i386` | installed — **not** `gamemode:i386`, which conflicts with the native `gamemode` metapackage over daemon ownership. The 32-bit runtime libs are the actual thing 32-bit games need; installing the full `gamemode:i386` metapackage alongside native `gamemode` is a resolver conflict by design in Debian's packaging. |
| mangohud.x86_64 / mangohud.i686 | mangohud + mangohud:i386 | **blocked** — dependency `libspdlog1.15-fmt10` had no installable candidate anywhere in sid at the time (a mid-transition gap in the archive, not a naming issue). Retry later with `sudo apt-get install mangohud mangohud:i386`; it may resolve once the spdlog transition finishes. |

Note: dwm-titus's `install.sh` normally pulls a COPR-patched gamescope on Fedora. No COPR equivalent was needed here — Debian sid ships its own gamescope build directly in main.

## Build and install

Built from a real, clean git clone at `/home/kartik/dwm-titus` on the host (`git remote -v` confirms `origin` = `https://github.com/christitustech/dwm-titus`, `up to date with origin/main`). This is distinct from `/home/kartik/Github/dwm-titus-main`, a static mirror copied over earlier via WinSCP for reference — that one was never built from.

```bash
cd /home/kartik/dwm-titus
make            # produced ./dwm (132,440 bytes)
sudo make install
```

`make install` is designed to be run once, as root, and handles the root/non-root split itself: it re-execs the build step as the invoking user via `SUDO_USER`/`runuser` (never builds as root), runs `install-system` for the system-wide pieces, then drops back to the target user for `install-user`. No manual profile-splitting or separate `install-system`/`install-user` invocations were needed.

Installed artifacts, confirmed on disk after the run:

| What | Where |
|---|---|
| Binary | `/usr/local/bin/dwm` |
| Xsession entry (what lightdm/slick-greeter shows in the session picker) | `/usr/share/xsessions/dwm.desktop` |
| User config | `/home/kartik/.config/dwm-titus/` (hotkeys.toml, themes.toml, window-rules.toml) |
| Quickshell config | `/home/kartik/.config/quickshell` (replaced) |
| Data dir (synced repo copy, scripts) | `/home/kartik/.local/share/dwm-titus/` |
| `.xinitrc` | seeded (didn't previously exist) |
| Autostart overrides | light-locker.desktop, picom.desktop, polkit-mate-authentication-agent-1.desktop |

Also installed by the same `make install` run: the manpage, every `scripts/dwm-*` helper command into `/usr/local/bin`, the privileged `dwm-settings-display-root` helper, Meslo font aliases (fontconfig, separate from actually installing the font files), and the Capitaine cursor theme.

## Non-package steps

These are identical regardless of distro — `install.sh` does them outside dnf/apt entirely, so they were reproduced by hand following the exact same logic (URLs, checksums, clone targets) read directly out of `install.sh`.

- **Meslo Nerd Font**: downloaded `Meslo.zip` v3.4.0 from the `ryanoasis/nerd-fonts` GitHub release, verified its sha256 against the pin in `install.sh` (`13b502ac8c2bd9d3161018064560e23cd42b175bb730780a270975265a19ad57`) — matched. Unzipped `.ttf` files into `~/.local/share/fonts/Meslo` (72 files), ran `fc-cache -f`. `fc-list` confirms MesloLGS Nerd Font is registered.
- **Nordic GTK theme**: `git clone --depth 1 --branch master https://github.com/EliverLara/Nordic.git`, then copied system-wide to `/usr/share/themes/Nordic` with the same permission fixups (`0755` dirs, `0644` files) `install.sh` applies. Confirmed `gtk-3.0`/`gtk-4.0` present.
- **Nord wallpapers**: `git clone https://github.com/ChrisTitusTech/nord-background.git ~/Pictures/backgrounds`.
- **Herdr**: **skipped, at Kartik's confirmation.** `scripts/install-herdr` pins the official installer's sha256 as `57c35622122f672ac311cbd7784be6af60912910287229492679033162b4604c`, but the installer currently served at `https://herdr.dev/install.sh` hashes to `3db3af8375006e193a393b5e3129feb237f30bc6f053fffbe1dc75da1f3d9ac4` — a mismatch on the integrity check that exists specifically to catch a changed/tampered installer. The fetched script's content looked like an ordinary, unremarkable Herdr installer (no signs of tampering), so this is most likely a stale pin in the dwm-titus repo rather than a compromise, but that could not be independently confirmed from this session, so the check was not bypassed and the pin was not silently updated. If Herdr is wanted later: check whether upstream `christitustech/dwm-titus` has since refreshed the pin, or have Kartik independently verify the new hash from a trusted source before updating `scripts/install-herdr` by hand.

## Host details

Debian GNU/Linux forky/sid, hostname `dell-optiplex`, at 192.168.0.222, user `kartik`. SSH reachable via password auth; from this Windows machine, `plink -batch -pw <password> -hostkey "SHA256:GTy8F9rJKk8xzModEE3ZGyWHR0RV777caDjSc9AY2cI" kartik@192.168.0.222 "<command>"` is the working non-interactive pattern (the `-hostkey` flag is needed once per session since `-batch` mode can't interactively confirm a new host key). `sudo` requires a password (no passwordless sudo configured) — piped via `echo <password> | sudo -S <command>`.

A standalone reference script, `dwm-titus-debian-install.sh` at this repo's root, captures the package-install commands from this port, including the build-time-discovered `libx11-xcb-dev`/`libxcb-res0-dev` additions.

## Outcome

Confirmed working by Kartik on 2026-08-24: dwm launches successfully from the lightdm/slick-greeter session picker.

## Follow-up (2026-08-24): icon theme support added to `theme-apply.sh`

Kartik installed `papirus-icon-theme` on the host and wanted it applied. `scripts/theme-apply.sh` (the script dwm-titus runs on every theme reload) had no icon-theme handling at all, and its GTK2 block (`~/.gtkrc-2.0`) fully overwrites the file on every run — so a manual one-off fix would have been silently wiped on the next theme switch. Patched the script itself instead of hand-editing config files.

The patch mirrors the script's existing `gtk_theme`/`default_gtk_theme`/`gtk_theme_available` pattern exactly:

- Added `icon_theme_available()` (searches `~/.local/share/icons`, `~/.icons`, `/usr/local/share/icons`, `/usr/share/icons`, same as the GTK theme lookup) and `default_icon_theme()` (returns `Papirus-Dark` in dark mode, `Papirus-Light` in light mode — Papirus was the theme Kartik had installed and asked for).
- `ICON_THEME_NAME` reads an optional `icon_theme` key from the active theme's `[theme.*]` section in `themes.toml` (none set yet, so it falls through to the default), with a fallback to `Adwaita` if the resolved name isn't actually installed — same safety net the GTK theme lookup already has.
- GTK3 and GTK4 blocks each got a new `gtk_ini_set ... "gtk-icon-theme-name" "$ICON_THEME_NAME"` call, using the script's existing idempotent ini-key helper.
- The GTK2 `printf` that rebuilds `~/.gtkrc-2.0` now includes `gtk-icon-theme-name` in the same overwrite, so it's no longer lost on the next run.
- Also added to the live-update paths for consistency with how cursor/GTK theme are already propagated: `gsettings set org.gnome.desktop.interface icon-theme` and `xfconf-query ... /Net/IconThemeName`.

Deployed to all three copies that exist on the host — the source at `/home/kartik/dwm-titus/scripts/theme-apply.sh`, the data-dir copy at `~/.local/share/dwm-titus/scripts/theme-apply.sh`, and the actually-invoked installed copy at `/usr/local/bin/theme-apply.sh` (root-owned; updated via `sudo cp` + `chown root:root`). The git clone alone is not what runs at theme-reload time — both deployed copies had to be updated too, or the change would have had no effect. Verified by running `theme-apply.sh` directly and confirming `gtk-icon-theme-name=Papirus-Dark` landed in `~/.config/gtk-3.0/settings.ini`, `~/.config/gtk-4.0/settings.ini`, and `~/.gtkrc-2.0`.

No changes were made to `themes.toml` — an `icon_theme` key per theme section is supported by the script (mirroring `gtk_theme`) but none is set, so every theme currently gets the dark/light default. Set one explicitly per theme in `~/.config/dwm-titus/themes.toml` if a different icon theme is ever wanted for a specific theme.

## Follow-up (2026-08-24): xrdp remote access to the dwm-titus session

Kartik wanted to reach the dwm-titus session remotely over RDP. Lower blast radius than the earlier NetworkManager work — installing a new service and opening a new port, not modifying live network config the SSH session depends on — so no console-access gate was needed here.

- Installed `xrdp` (0.10.6.1-2) and `xorgxrdp` (1:0.10.5-2) from the Debian repo — the modern Xorg-backend RDP stack, not the legacy Xvnc one. Each RDP login gets its own virtual X server via `xorgxrdp`'s driver; it doesn't touch the physical GPU/display, so it runs independently of the existing lightdm/console dwm session with no conflict.
- xrdp has no session picker equivalent to lightdm's `/usr/share/xsessions`. To pin the RDP session to dwm-titus specifically (rather than whatever `/etc/X11/Xsession`'s default fallback would pick), created `/home/kartik/.xsession`:
  ```
  exec /usr/local/bin/dwm
  ```
  This mirrors `/usr/share/xsessions/dwm.desktop`'s own `Exec=/usr/local/bin/dwm` line exactly — same binary, same autostart (`dwm.c`'s `runautostart()` calls `scripts/autostart.sh` internally, so the raw binary is the complete session; no wrapper script needed).
- **Real gap found and fixed**: the `xrdp` system user wasn't in the `ssl-cert` group, so it couldn't read `/etc/xrdp/key.pem` (symlinked to `/etc/ssl/private/ssl-cert-snakeoil.key`, `root:ssl-cert 640`) — the package's postinst doesn't add this automatically on Debian. Fixed with `sudo adduser xrdp ssl-cert` + `systemctl restart xrdp xrdp-sesman`. Confirmed via `/var/log/xrdp.log`: `Using default X.509 certificate: /etc/xrdp/cert.pem` / `Using default X.509 key file: /etc/xrdp/key.pem` logged cleanly on the next connection attempt, no permission error.
- No firewall changes needed at the time — `nft list ruleset` on this host was empty (no active rules) as of 2026-08-24, so port 3389 wasn't blocked. **Stale as of 2026-08-25**: the Minecraft setup (`docs/minecraft-server-setup.md`) later added a default-drop `nftables` ruleset that didn't include 3389, which silently broke xrdp connectivity until fixed 2026-08-26 (see that doc's "Follow-up (2026-08-26)" section).
- Verified: `xrdp`/`xrdp-sesman` both `enabled` and `active`, `ss -tulpn` shows `*:3389` listening.

**Not verified from this session**: an actual graphical RDP login, since access here is shell-only (no RDP client available to drive one end-to-end). Kartik still needs to confirm from a real RDP client (e.g. Windows' `mstsc` to `192.168.0.222:3389`, user `kartik`) that dwm renders correctly — statusbar, wallpaper, and the rest of `autostart.sh`'s effects — before treating this as fully done.

## Follow-up (2026-08-25): LightDM autologin to dwm-titus

Kartik wanted the box to boot straight into the dwm-titus desktop with no manual login — consistent with wanting this as a low-touch homelab/remote-access box (see the xrdp setup above).

`lightdm --show-config` confirmed `/etc/lightdm/lightdm.conf`'s `[Seat:*]` section is the sole authoritative config on this host — no `/etc/lightdm/lightdm.conf.d/` drop-in directory exists or is scanned — so the settings were added there directly (original backed up alongside as `lightdm.conf.bak-20260825`):

```
[Seat:*]
autologin-user=kartik
autologin-user-timeout=0
autologin-session=dwm
user-session=dwm
```

The xsession id is `dwm` (the filename of `/usr/share/xsessions/dwm.desktop`), even though its `Name=` field displays as "dwm-titus" in the greeter — using the display name instead of the filename here would silently fail to autologin. No PAM or group changes were needed: Debian's `lightdm-autologin` PAM service already permits any non-root user passwordlessly by default.

Confirmed working by Kartik after a manual reboot. Restarting/reconfiguring lightdm live would kill any active graphical session on seat0, so a reboot — not a live `systemctl restart lightdm` — is the safe way to apply a change like this.

## Follow-up (2026-08-25): LightDM/dwm session-churn diagnosis — resolved as a non-issue

Kartik asked to diagnose a pattern in `systemctl status lightdm` output: a burst of `greeter-session-opened` → `kartik-session-opened` → `greeter-session-opened` again within about 14 seconds, which looked like the autologin session might be crash-looping back to the greeter.

Full `journalctl`/`~/.xsession-errors` analysis (using `mcp__headroom__headroom_retrieve` to recover content the tool output had compressed) showed two completely normal, deliberate logout sequences — one about 7 minutes long, the other about 8.5 seconds — with no crashes, segfaults, or errors anywhere in either. `dwm-titus`'s own `scripts/autostop.sh` (the cleanup hook `dwm.c`'s `runautostop()` calls on normal exit — confirmed by grepping `dwm.c` for `autostop`) is exactly what produces this pattern on an ordinary logout: it calls `loginctl terminate-session` for an X11 display-manager session, which is what makes LightDM cycle back to a fresh greeter session immediately afterward. That's expected behavior for *any* logout under this setup, not a symptom of a crash.

This was **not independently confirmed by Kartik against what he was actually seeing at the physical console** — the diagnosis is based entirely on log evidence showing no error condition, and Kartik moved on to other work before responding to that question. Revisit if the same pattern is reported again alongside an actual observed symptom (frozen screen, unexpected logout, etc.) rather than just the systemd status output.
