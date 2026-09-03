#!/usr/bin/env bash
# Debian/apt package equivalents for ChrisTitusTech/dwm-titus (Fedora-only upstream).
#
# dwm-titus's own install.sh hard-rejects any non-Fedora distro, so this script
# does NOT reproduce that installer. It only installs the apt equivalents of
# every package dwm-titus-main/scripts/dwm-packages.sh lists for Fedora, grouped
# into the same profiles. After running this, build dwm yourself from the
# dwm-titus source tree (make, make install-system, make install-user) and copy
# over the config files the upstream installer would otherwise place.
#
# Verified against packages.debian.org, suite=unstable (sid), 2026-08-24.
#
# Not covered here (same on every distro, not apt packages):
#   - Herdr           curl-installed from herdr.dev
#   - Meslo Nerd Font  downloaded + sha256-verified from a GitHub release
#   - Nordic GTK theme git clone https://github.com/EliverLara/Nordic
#   - Nord wallpapers  git clone https://github.com/ChrisTitusTech/nord-background
#
# Known gap: deepin-gtk-theme (Fedora) has no Debian package. No substitute
# installed below; pick a different GTK theme or build it from source.

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

# theme-gtk (deepin-gtk-theme skipped — no Debian package exists)
sudo apt install -y arc-theme adw-gtk3 numix-gtk-theme yaru-theme-gtk \
	bluebird-gtk-theme

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

# gaming (x86_64 only — needs 32-bit multiarch for gamemode/mangohud)
# Uncomment if you want the gaming profile:
# sudo dpkg --add-architecture i386
# sudo apt update
# sudo apt install -y steam-installer gamescope gamemode gamemode:i386 \
#   mangohud mangohud:i386
