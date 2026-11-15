#!/usr/bin/env bash
# install-c920-udev-rule.sh: install c920-apply-settings, c920-settings@.service and a udev rule
# that re-applies the Logitech C920 (046d:08e5) "stable" fix on every plug-in, then apply it now.
# Usage: scripts/install-c920-udev-rule.sh [EXPOSURE 3-2047, default 250] [FOCUS 0-250 step 5, default 0]

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

rule="# Installed by scripts/install-c920-udev-rule.sh — Logitech C920: manual
# exposure + autofocus off on every plug-in/boot, via $UNIT_FILE.
ACTION==\"add\", SUBSYSTEM==\"video4linux\", ATTRS{idVendor}==\"046d\", ATTRS{idProduct}==\"08e5\", ATTR{index}==\"0\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"c920-settings@%k.service\""

printf 'Installing %s, %s and %s:\n\n%s\n\n%s\n\n' "$HELPER" "$UNIT_FILE" "$RULE_FILE" "$unit" "$rule"
sudo install -m 755 "$HELPER_SRC" "$HELPER"
printf '%s\n' "$unit" | sudo tee "$UNIT_FILE" >/dev/null
printf '%s\n' "$rule" | sudo tee "$RULE_FILE" >/dev/null
sudo systemctl daemon-reload
sudo udevadm control --reload

found=0
failed=0
for sys in /sys/class/video4linux/video*; do
	[ "$(cat "$sys/index" 2>/dev/null)" = 0 ] || continue
	props=$(udevadm info -q property -p "$sys" 2>/dev/null) || continue
	{ grep -qx 'ID_VENDOR_ID=046d' <<<"$props" && grep -qx 'ID_MODEL_ID=08e5' <<<"$props"; } || continue
	node="${sys##*/}"
	found=$((found + 1))
	printf 'Applying to /dev/%s now...\n' "$node"
	sudo systemctl start "c920-settings@$node.service" || failed=$((failed + 1))
done
[ "$found" -gt 0 ] || echo "No C920 plugged in right now; it will be set up when it appears."
[ "$failed" -eq 0 ] ||
	die "rule installed, but applying the settings failed on $failed of $found plugged-in C920(s); see: journalctl -u 'c920-settings@*' -n 20"

echo "Done. Check with: journalctl -u 'c920-settings@*' -n 20"
