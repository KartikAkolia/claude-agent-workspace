#!/usr/bin/env bash
# Debian apt equivalents of the Fedora package profiles in dwm-titus-main/scripts/dwm-packages.sh.
# Afterwards build dwm from the dwm-titus tree with `sudo make install`. The gaming profile,
# the non-package steps and the packages Debian lacks are in its doc.
# Docs: docs/dwm-titus-debian-port.md

set -euo pipefail

sudo apt update
sudo apt install -y gcc make pkgconf libx11-dev libxft-dev libxinerama-dev \
	libxrender-dev libimlib2-dev libxcb1-dev libxcb-util-dev libfreetype-dev \
	libfontconfig-dev libx11-xcb-dev libxcb-res0-dev
sudo apt install -y xserver-xorg xinit x11-xserver-utils xinput x11-xkb-utils
sudo apt install -y dbus-x11 curl git procps psmisc unzip util-linux xclip \
	xdotool x11-utils xdg-utils
sudo apt install -y quickshell picom feh dex mate-polkit alsa-utils \
	brightnessctl pulseaudio-utils pipewire pavucontrol pipewire-pulse \
	wireplumber libnotify-bin light-locker xserver-xorg-input-libinput \
	bluez blueman playerctl
sudo apt install -y thunar gvfs gvfs-backends tumbler thunar-archive-plugin \
	file-roller xdg-user-dirs xdg-desktop-portal-gtk gnome-keyring \
	libpam-gnome-keyring network-manager rsync
sudo apt install -y dconf-cli
sudo apt install -y arc-theme numix-gtk-theme yaru-theme-gtk bluebird-gtk-theme
sudo apt install -y qt6ct qt5ct
sudo apt install -y fonts-noto-color-emoji fonts-noto-mono
sudo apt install -y qt6-declarative-dev
sudo apt install -y lightdm slick-greeter
sudo apt install -y alacritty kitty
sudo apt install -y maim
