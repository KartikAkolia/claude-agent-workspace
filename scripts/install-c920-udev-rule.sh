#!/usr/bin/env bash
# install-c920-udev-rule.sh — install a udev rule that applies the Logitech
# C920 (USB 046d:08e5) "stable" fix every time the camera appears: manual
# exposure + autofocus off, the fix from
# https://christitus.com/logitech-c920-linux-driver/ for C920 lag on Linux.
# webcam-tui.sh's "stable" preset applies the same fix, but only for the
# current session — v4l2 controls reset when the camera is replugged or the
# machine reboots, which is what this rule covers.
#
# Uses this kernel's control names (auto_exposure/focus_automatic_continuous),
# not the article's exposure_auto/focus_auto, which v4l2-ctl rejects here as
# "unknown control" (checked 2026-10-18 on /dev/video2). Each control is set
# in its own v4l2-ctl call, auto-mode switches first: the C920 refuses
# focus_absolute with "Permission denied" while autofocus is still on.
#
# Matches by USB vendor/product ID rather than /dev/videoN, since the node
# number depends on probe order, and on ATTR{index}=="0" so only the
# capture node gets it, not the C920's UVC metadata node.
#
# Needs root to write /etc/udev/rules.d, so run it in a real terminal:
#   scripts/install-c920-udev-rule.sh [EXPOSURE] [FOCUS]
# EXPOSURE: exposure_time_absolute, 3-2047 (default 250, the C920's own default)
# FOCUS:    focus_absolute, 0-250 in steps of 5 (default 0 = infinity)
# Rerun with new values to replace the rule; `sudo rm` the file to remove it.

set -euo pipefail

readonly RULE_FILE=/etc/udev/rules.d/99-logitech-c920.rules
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

V4L2_CTL=$(command -v v4l2-ctl) || die "v4l2-ctl not found (install v4l-utils)"

# udev substitutes $devnode itself, and would try to substitute any other
# $name too, so the command is written out per control with no shell
# variables of its own.
set_ctrls=""
for ctrl in auto_exposure=1 exposure_time_absolute="$EXPOSURE" \
	focus_automatic_continuous=0 focus_absolute="$FOCUS"; do
	set_ctrls+="${set_ctrls:+ && }$V4L2_CTL -d \$devnode -c $ctrl"
done

rule="# Installed by scripts/install-c920-udev-rule.sh — Logitech C920: manual
# exposure + autofocus off on every plug-in/boot.
ACTION==\"add\", SUBSYSTEM==\"video4linux\", ATTRS{idVendor}==\"046d\", ATTRS{idProduct}==\"08e5\", ATTR{index}==\"0\", RUN+=\"/bin/sh -c '$set_ctrls'\""

printf 'Installing %s:\n\n%s\n\n' "$RULE_FILE" "$rule"
printf '%s\n' "$rule" | sudo tee "$RULE_FILE" >/dev/null
sudo udevadm control --reload
# Re-fire "add" for already-plugged cameras so it takes effect now, not only
# at the next replug/boot. The rule itself narrows this down to the C920.
sudo udevadm trigger --action=add --subsystem-match=video4linux --attr-match=index=0

echo "Done. Check with: v4l2-ctl -d <C920 node> -C auto_exposure,exposure_time_absolute,focus_automatic_continuous,focus_absolute"
