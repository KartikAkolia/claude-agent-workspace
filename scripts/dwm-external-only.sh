#!/bin/sh
# While the external monitor is connected, run it at 1920x1080 at its highest
# refresh rate as the only display; otherwise keep the internal panel lit.
#   dwm-external-only.sh          apply once
#   dwm-external-only.sh watch    keep applying it on every plug or unplug
# Docs: docs/dwm-external-display.md (install, hotplug detection, recovery)
set -u

external=${DWM_EXTERNAL_OUTPUT:-HDMI-1-0}
internal=${DWM_INTERNAL_OUTPUT:-eDP-1}
mode=1920x1080

log() {
	printf 'dwm-external-only: %s\n' "$*" >&2
}

# Print "ext_connected ext_lit ext_placed ext_best ext_current int_found
# int_lit int_placed" from $query. placed: at 0x0, and for the external also
# primary and in $mode. Rates are "-" when $mode is unlisted.
layout_state() {
	printf '%s\n' "$query" | awk -v ext="$external" -v intern="$internal" -v mode="$mode" '
		/^[^ ]/ { inside = ($1 == ext) }
		$1 == ext {
			connected = ($2 == "connected")
			ext_lit = ($0 ~ / [0-9]+x[0-9]+\+[0-9]+\+[0-9]+ /)
			ext_placed = (index($0, " primary " mode "+0+0 ") > 0)
			next
		}
		$1 == intern {
			int_found = 1
			int_lit = ($0 ~ / [0-9]+x[0-9]+\+[0-9]+\+[0-9]+ /)
			int_placed = ($0 ~ / [0-9]+x[0-9]+\+0\+0 /)
			next
		}
		inside && $1 == mode {
			for (i = 2; i <= NF; i++) {
				r = $i
				if (r ~ /\*/) current = r
				gsub(/[*+]/, "", r)
				if (r + 0 > best + 0) best = r
			}
		}
		END {
			gsub(/[*+]/, "", current)
			printf "%d %d %d %s %s %d %d %d\n", connected, ext_lit, ext_placed,
				(best == "" ? "-" : best), (current == "" ? "-" : current),
				int_found, int_lit, int_placed
		}
	'
}

# Acts on $query. Returns 0 only once the wanted layout is in place.
apply() {
	# shellcheck disable=SC2046 # layout_state prints exactly eight words.
	set -- $(layout_state)
	[ $# = 8 ] || return 1
	ext_connected=$1 ext_lit=$2 ext_placed=$3 ext_best=$4 ext_current=$5
	int_found=$6 int_lit=$7 int_placed=$8
	# xrandr only warns, exit 0, about an output that doesn't exist.
	[ "$int_found" = 1 ] || {
		log "no output named $internal"
		return 1
	}

	if [ "$ext_connected" = 1 ]; then
		# No $mode listed: EDID not read yet, or a monitor without it. Leave
		# the layout alone; the watcher retries.
		[ "$ext_best" != - ] || return 1
		[ "$ext_current" = "$ext_best" ] && [ "$ext_placed" = 1 ] && [ "$int_lit" = 0 ] && return 0
		# Light the external first; turn the internal off only once that worked.
		xrandr --output "$external" --mode "$mode" --rate "$ext_best" --pos 0x0 --primary || return 1
		xrandr --output "$internal" --off || return 1
		log "$external at $mode ${ext_best} Hz, $internal off"
		return 0
	fi

	[ "$int_lit" = 1 ] && [ "$int_placed" = 1 ] && [ "$ext_lit" = 0 ] && return 0
	xrandr --output "$internal" --auto --pos 0x0 --primary --output "$external" --off || return 1
	log "$external disconnected, $internal on"
}

# Polls RandR's cached state (--current does not re-probe connectors): the
# NVIDIA HDMI port sends no hotplug uevent. A change must hold for two polls in
# a row before it is acted on, and a failed apply is retried on every poll,
# logging only its first failure per cable state. Exits once xrandr fails five
# polls in a row (thirty before the first successful read, to ride out login).
watch() {
	applied=
	previous=
	failed=0
	misses=0
	limit=30
	while :; do
		if query=$(xrandr --current 2>/dev/null); then
			misses=0
			limit=5
		else
			misses=$((misses + 1))
			if [ "$misses" -ge "$limit" ]; then
				log "cannot reach the X server on ${DISPLAY:-no DISPLAY}; stopping"
				exit 0
			fi
			sleep 2
			continue
		fi
		sample=$(layout_state | cut -d' ' -f1)
		[ "$sample" = "$previous" ] || failed=0
		if [ "$sample" = "$previous" ] && [ "$sample" != "$applied" ]; then
			if output=$(apply 2>&1); then
				[ -z "$output" ] || printf '%s\n' "$output" >&2
				applied=$sample
				failed=0
			elif [ "$failed" = 0 ]; then
				[ -z "$output" ] || printf '%s\n' "$output" >&2
				log "could not apply the layout yet; retrying every 2 seconds"
				failed=1
			fi
		fi
		previous=$sample
		sleep 2
	done
}

case ${1:-} in
"")
	query=$(xrandr --current) || exit 1
	apply
	;;
watch) watch ;;
*)
	log "usage: dwm-external-only.sh [watch]"
	exit 2
	;;
esac
