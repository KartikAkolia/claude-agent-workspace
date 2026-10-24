#!/usr/bin/env bash
# c920-apply-settings.sh — apply the Logitech C920 "stable" settings (manual
# exposure, autofocus off) to one capture node, and keep re-applying until
# the camera actually holds them. Run by c920-settings@<videoN>.service,
# which install-c920-udev-rule.sh's udev rule starts whenever the C920
# appears; not normally run by hand.
#
# Why a loop rather than one pass: straight after plug-in the C920 accepts
# every v4l2-ctl write but sometimes drops some of them (seen 2026-10-21 —
# one replug kept exposure but not focus, a boot kept focus but not
# exposure, the next replug kept all four), and it can drift off a manual
# exposure for a second or two after the mode switch. Why a systemd unit
# rather than udev's own RUN+=: udev kills RUN commands that take this long.
#
# Usage: c920-apply-settings.sh DEVICE EXPOSURE FOCUS

set -uo pipefail

readonly TRIES=10 SETTLE_SECS=2

[ "$#" -eq 3 ] || {
	printf 'usage: %s DEVICE EXPOSURE FOCUS\n' "${0##*/}" >&2
	exit 2
}
readonly DEV="$1"
# Auto-mode switches first: the C920 refuses focus_absolute with
# "Permission denied" while autofocus is still on.
readonly WANT=(auto_exposure=1 "exposure_time_absolute=$2" focus_automatic_continuous=0 "focus_absolute=$3")

# Current value only, as v4l2-ctl -C reports it ("name: 1 (Manual Mode)" -> "1").
ctrl_cur() {
	v4l2-ctl -d "$DEV" -C "$1" 2>/dev/null | awk -F': ' '{ split($2, v, " "); print v[1]; exit }'
}

for ((try = 1; try <= TRIES; try++)); do
	[ -e "$DEV" ] || {
		printf '%s went away, giving up\n' "$DEV" >&2
		exit 1
	}
	for ctrl in "${WANT[@]}"; do
		v4l2-ctl -d "$DEV" -c "$ctrl" 2>/dev/null
	done
	sleep "$SETTLE_SECS"
	off=()
	for ctrl in "${WANT[@]}"; do
		[ "$(ctrl_cur "${ctrl%%=*}")" = "${ctrl#*=}" ] || off+=("$ctrl")
	done
	if [ "${#off[@]}" -eq 0 ]; then
		printf '%s: settings held on try %d\n' "$DEV" "$try"
		exit 0
	fi
	printf '%s: try %d, not held yet: %s\n' "$DEV" "$try" "${off[*]}"
done
printf '%s: gave up after %d tries\n' "$DEV" "$TRIES" >&2
exit 1
