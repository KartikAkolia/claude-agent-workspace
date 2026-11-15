#!/usr/bin/env bash
# c920-apply-settings.sh: apply the Logitech C920 "stable" v4l2 settings to one capture node and
# re-apply until they hold (right after plug-in it drops some writes). Run by c920-settings@.service.
# Usage: c920-apply-settings.sh DEVICE EXPOSURE FOCUS
# Docs: docs/logitech-c920-webcam.md

set -uo pipefail

readonly TRIES=10 SETTLE_SECS=2

[ "$#" -eq 3 ] || {
	printf 'usage: %s DEVICE EXPOSURE FOCUS\n' "${0##*/}" >&2
	exit 2
}
readonly DEV="$1"
readonly WANT=(auto_exposure=1 "exposure_time_absolute=$2" focus_automatic_continuous=0 "focus_absolute=$3")

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
