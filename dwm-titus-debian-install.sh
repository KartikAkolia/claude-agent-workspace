#!/usr/bin/env bash
# Debian/apt package equivalents for ChrisTitusTech/dwm-titus (Fedora-only upstream).
#
# dwm-titus's own install.sh hard-rejects any non-Fedora distro, so this script
# does NOT reproduce that installer. It only installs the apt equivalents of
# every package dwm-titus-main/scripts/dwm-packages.sh lists for Fedora, grouped
# into the same profiles. After running this, build and install dwm from the
# dwm-titus source tree with a single `sudo make install` run from your own
# account (the port ran `make` first; see docs/dwm-titus-debian-port.md). It
# takes the target user from SUDO_USER (falling back to USER), builds as that
# user, installs system files as root and user files as that user, and refuses
# to install when the target user is root, e.g. from a plain root shell. The
# non-package steps below stay manual.
#
# Verified against packages.debian.org, suite=unstable (sid), 2026-08-24.
#
# Not covered here (same on every distro, not apt packages):
#   - Herdr           curl-installed from herdr.dev
#   - Meslo Nerd Font  downloaded + sha256-verified from a GitHub release
#   - Nordic GTK theme git clone https://github.com/EliverLara/Nordic
#   - Nord wallpapers  git clone https://github.com/ChrisTitusTech/nord-background
#
# Known gaps (Fedora theme-gtk packages with no Debian package; no substitute
# installed below):
#   - adw-gtk3-theme   in no Debian suite; upstream ships it only as a Flatpak
#                      (org.gtk.Gtk3theme.adw-gtk3) or a manual GitHub release
#   - deepin-gtk-theme not in sid; pick another GTK theme or build from source

set -euo pipefail

sudo apt update

# build
sudo apt install -y gcc make pkgconf libx11-dev libxft-dev libxinerama-dev \
	libxrender-dev libimlib2-dev libxcb1-dev libxcb-util-dev libfreetype-dev \
	libfontconfig-dev libx11-xcb-dev libxcb-res0-dev

# x11
sudo apt install -y xserver-xorg xinit x11-xserver-utils xinput x11-xkb-utils

# runtime-required
sudo apt install -y dbus-x11 curl git procps psmisc unzip util-linux xclip \
	xdotool x11-utils xdg-utils

# desktop
sudo apt install -y quickshell picom feh dex mate-polkit alsa-utils \
	brightnessctl pulseaudio-utils pipewire pavucontrol pipewire-pulse \
	wireplumber libnotify-bin light-locker xserver-xorg-input-libinput \
	bluez blueman playerctl

# desktop-optional
sudo apt install -y thunar gvfs gvfs-backends tumbler thunar-archive-plugin \
	file-roller xdg-user-dirs xdg-desktop-portal-gtk gnome-keyring \
	libpam-gnome-keyring network-manager rsync

# theme
sudo apt install -y dconf-cli

# theme-gtk (adw-gtk3 and deepin-gtk-theme skipped — no Debian package exists)
sudo apt install -y arc-theme numix-gtk-theme yaru-theme-gtk bluebird-gtk-theme

# theme-optional
sudo apt install -y qt6ct qt5ct

# fonts
sudo apt install -y fonts-noto-color-emoji fonts-noto-mono

# qml-development
sudo apt install -y qt6-declarative-dev

# lightdm
sudo apt install -y lightdm slick-greeter

# terminal
sudo apt install -y alacritty kitty

# screenshot-optional
sudo apt install -y maim

# gaming (x86_64 only — needs 32-bit multiarch for the i386 packages)
# For the gaming profile, uncomment every command below, including the separate
# mangohud line. Use the gamemode i386 runtime libraries, not gamemode:i386,
# which conflicts with native gamemode over daemon ownership:
# sudo dpkg --add-architecture i386
# sudo apt update
# sudo apt install -y steam-installer gamescope gamemode \
#   libgamemode0:i386 libgamemodeauto0:i386
# mangohud + mangohud:i386 are separate because they were blocked when this was
# ported (dependency libspdlog1.15-fmt10 had no installable candidate in sid);
# a failure here would otherwise stop the line above:
# sudo apt install -y mangohud mangohud:i386
