#!/usr/bin/env bash
# install-c920-udev-rule.sh — install a udev rule that applies the Logitech
# C920 (USB 046d:08e5) "stable" fix every time the camera appears: manual
# exposure + autofocus off, the fix from
# https://christitus.com/logitech-c920-linux-driver/ for C920 lag on Linux.
# webcam-tui.sh's "stable" preset applies the same fix, but only for the
# current session — v4l2 controls reset when the camera is replugged or the
# machine reboots, which is what this rule covers.
#
# The rule doesn't set the controls itself: it starts
# c920-settings@<videoN>.service, which runs c920-apply-settings.sh to apply
# them and re-apply until they hold. Setting them straight from the rule
# (this script's first version) only worked some of the time — see that
# script's header for what the C920 does right after plug-in.
#
# Uses this kernel's control names (auto_exposure/focus_automatic_continuous),
# not the article's exposure_auto/focus_auto, which v4l2-ctl rejects here as
# "unknown control" (checked 2026-10-18 on /dev/video2).
#
# Matches by USB vendor/product ID rather than /dev/videoN, since the node
# number depends on probe order, and on ATTR{index}=="0" so only the
# capture node gets it, not the C920's UVC metadata node.
#
# Installs, all via sudo (so run it in a real terminal):
#   /usr/local/bin/c920-apply-settings          (copy of c920-apply-settings.sh)
#   /etc/systemd/system/c920-settings@.service
#   /etc/udev/rules.d/99-logitech-c920.rules
# then applies the settings to an already-plugged C920 straight away.
#
#   scripts/install-c920-udev-rule.sh [EXPOSURE] [FOCUS]
# EXPOSURE: exposure_time_absolute, 3-2047 (default 250, the C920's own default)
# FOCUS:    focus_absolute, 0-250 in steps of 5 (default 0 = infinity)
# Rerun with new values to replace all three; `sudo rm` them to remove it.

set -euo pipefail

readonly RULE_FILE=/etc/udev/rules.d/99-logitech-c920.rules
readonly UNIT_FILE=/etc/systemd/system/c920-settings@.service
readonly HELPER=/usr/local/bin/c920-apply-settings
HELPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/c920-apply-settings.sh"
readonly HELPER_SRC
readonly EXPOSURE="${1:-250}"
readonly FOCUS="${2:-0}"

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

if ! [[ "$EXPOSURE" =~ ^[1-9][0-9]*$ ]] || [ "$EXPOSURE" -lt 3 ] || [ "$EXPOSURE" -gt 2047 ]; then
	die "EXPOSURE must be 3-2047, got '$EXPOSURE'"
fi
if ! [[ "$FOCUS" =~ ^(0|[1-9][0-9]*)$ ]] || [ "$FOCUS" -gt 250 ] || [ $((FOCUS % 5)) -ne 0 ]; then
	die "FOCUS must be 0-250 in steps of 5, got '$FOCUS'"
fi

command -v v4l2-ctl >/dev/null || die "v4l2-ctl not found (install v4l-utils)"
[ -f "$HELPER_SRC" ] || die "missing $HELPER_SRC"

unit="# Installed by scripts/install-c920-udev-rule.sh — started by
# $RULE_FILE when a Logitech C920 appears.
[Unit]
Description=Logitech C920 stable settings on /dev/%I

[Service]
Type=oneshot
ExecStart=$HELPER /dev/%I $EXPOSURE $FOCUS"

# %k is the kernel name (videoN). TAG+="systemd" makes systemd track the
# device so SYSTEMD_WANTS takes effect.
rule="# Installed by scripts/install-c920-udev-rule.sh — Logitech C920: manual
# exposure + autofocus off on every plug-in/boot, via $UNIT_FILE.
ACTION==\"add\", SUBSYSTEM==\"video4linux\", ATTRS{idVendor}==\"046d\", ATTRS{idProduct}==\"08e5\", ATTR{index}==\"0\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"c920-settings@%k.service\""

printf 'Installing %s, %s and %s:\n\n%s\n\n%s\n\n' "$HELPER" "$UNIT_FILE" "$RULE_FILE" "$unit" "$rule"
sudo install -m 755 "$HELPER_SRC" "$HELPER"
printf '%s\n' "$unit" | sudo tee "$UNIT_FILE" >/dev/null
printf '%s\n' "$rule" | sudo tee "$RULE_FILE" >/dev/null
sudo systemctl daemon-reload
sudo udevadm control --reload

# systemd only acts on SYSTEMD_WANTS when a device first appears, so a
# re-triggered "add" won't reach an already-plugged C920 — start its unit
# directly instead.
started=0
for sys in /sys/class/video4linux/video*; do
	[ "$(cat "$sys/index" 2>/dev/null)" = 0 ] || continue
	props=$(udevadm info -q property -p "$sys" 2>/dev/null) || continue
	if ! grep -qx 'ID_VENDOR_ID=046d' <<<"$props" || ! grep -qx 'ID_MODEL_ID=08e5' <<<"$props"; then
		continue
	fi
	node="${sys##*/}"
	printf 'Applying to /dev/%s now...\n' "$node"
	sudo systemctl start "c920-settings@$node.service" && started=$((started + 1))
done
[ "$started" -eq 0 ] && echo "No C920 plugged in right now; it will be set up when it appears."

echo "Done. Check with: journalctl -u 'c920-settings@*' -n 20"
