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
