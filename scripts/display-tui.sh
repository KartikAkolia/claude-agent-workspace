#!/usr/bin/env bash
# Whiptail TUI for granular X11 display management: resolution, refresh
# rate, layout/position, mirroring, rotation, and turning on connected
# displays that are off. Scratches an itch arandr doesn't: arandr has no
# refresh-rate control at all, and its layout editor is mouse-only.
#
# Drives xrandr directly; needs an X11 session. Not applicable under
# Wayland (no xrandr equivalent there worth wrapping the same way).
set -uo pipefail

# PROG, die, require_tools and wt (the whiptail wrapper, which draws
# display-only dialogs on /dev/tty) come from lib/tui.sh, shared with the
# other TUIs. It's found beside this script's real path, so a symlink to
# the script still works.
tui_lib="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/tui.sh"
if [ ! -r "$tui_lib" ]; then
	printf 'error: %s is missing; run %s from the repo checkout, or keep scripts/lib/ beside it\n' "$tui_lib" "${0##*/}" >&2
	exit 1
fi
# Linted on its own, so not followed here.
# shellcheck source=/dev/null
. "$tui_lib"

# --- xrandr state -------------------------------------------------------

# The text of one `xrandr --verbose`, which every parser below reads, so an
# action probes the outputs (and their EDIDs) once instead of once per
# question: each probe is slow, and on some panels it makes the picture
# flicker. main_menu loads it in the main shell before each action, so the
# pickers and helpers that action runs in $(...) subshells all inherit the
# same text. run_xrandr marks it stale after any change, and the next read
# probes again. --verbose's output header lines carry everything --query's
# do, so no parser needs --query.
#
# XR_LOOSE lists the XIDs of modes that belong to no output (made with
# --newmode and never --addmode'd). xrandr prints those after the last
# output, with print_verbose_mode, exactly like that output's own modes, so
# --verbose can't tell where its list ends. The plain listing can: there an
# output's modes are grouped one line per name ("   NAME  rate..."), and
# only these leftovers keep the "  NAME (0xNN) ..." form. --current reads
# that listing without probing the outputs again.
XR_STATE="" XR_LOOSE="" XR_LOADED=0
xr_load() {
	XR_STATE=$(xrandr --verbose 2>/dev/null) || XR_STATE=""
	XR_LOOSE=$(xrandr --current 2>/dev/null | awk '
        /^  [^ ]/ && match($0, /\(0x[0-9a-fA-F]+\)/) {
            printf "%s%s", sep, substr($0, RSTART + 1, RLENGTH - 2)
            sep = " "
        }')
	XR_LOADED=1
}

# Prints the loaded text, probing first only if it's stale or was never
# loaded. A probe from inside a subshell isn't kept, so call xr_load in the
# main shell before anything that reads repeatedly.
xr_state() {
	[ "$XR_LOADED" -eq 1 ] || xr_load
	printf '%s\n' "$XR_STATE"
}

# --- xrandr parsing ---------------------------------------------------

# One line per output: name|connected|primary(yes/no)|geometry(WxH+X+Y or empty)
# geometry is empty for a connected-but-disabled output (e.g. a laptop
# panel turned off while docked), same as for a disconnected one.
xrandr_outputs() {
	xr_state | awk '
        /^[^ \t]+ (connected|disconnected)/ {
            name=$1; status=$2; primary="no"; geom=""
            for (i=3;i<=NF;i++) {
                if ($i=="primary") primary="yes"
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) geom=$i
            }
            print name "|" status "|" primary "|" geom
        }'
}

connected_outputs() { xrandr_outputs | awk -F'|' '$2=="connected"'; }
active_outputs() { xrandr_outputs | awk -F'|' '$2=="connected" && $4!=""'; }

# One line per mode of output $1, in xrandr's order:
#   XID|WxH|RATE|current (1/0)|preferred (1/0)
# RATE is the refresh rate as xrandr prints it (two decimals), with "i"
# appended for an interlaced mode and "d" for a double-scan one. Read from
# --verbose, not --query: --query prints one line per mode *name*, so a
# size can turn up under several names (an interlaced "1920x1080i", a
# custom "1920x1080_60.00"), one name's line can repeat a rate (two timings
# that both round to 60.00), and nothing marks interlace. --verbose lists
# every mode on its own with its XID, flags, real size and rate. Modes that
# belong to no output are left out (see XR_LOOSE).
output_modes() {
	# Loaded here, in this shell, so XR_LOOSE is set before awk reads it; a
	# load inside the xr_state pipeline below would happen too late for that.
	[ "$XR_LOADED" -eq 1 ] || xr_load
	xr_state | awk -v out="$1" -v loose="$XR_LOOSE" '
        BEGIN { n = split(loose, l, " "); for (i = 1; i <= n; i++) skip[l[i]] = 1 }
        /^[^ \t]+ (connected|disconnected)/ { capture = ($1 == out); next }
        !capture { next }
        /^  [^ ]/ && match($0, /\(0x[0-9a-fA-F]+\)/) {
            xid = substr($0, RSTART + 1, RLENGTH - 2)
            # A mode of no output, listed after the last one (see XR_LOOSE).
            if (xid in skip) { xid = ""; next }
            kind = ($0 ~ / Interlace( |$)/ ? "i" : "") ($0 ~ / DoubleScan( |$)/ ? "d" : "")
            cur = ($0 ~ / \*current( |$)/)
            pref = ($0 ~ / \+preferred( |$)/)
            next
        }
        xid != "" && $1 == "h:" { w = $3; next }
        xid != "" && $1 == "v:" {
            rate = $NF
            sub(/Hz$/, "", rate)
            print xid "|" w "x" $3 "|" rate kind "|" cur "|" pref
            xid = ""
        }'
}

# Each size output $1 has a mode of, once, in xrandr's order.
resolutions_for_output() { output_modes "$1" | awk -F'|' '!seen[$2]++ { print $2 }'; }

# The rate choices for size $2 on output $1, in xrandr's order, as
# RATE|XID|note. Modes that would look the same in the menu (same size,
# rate and kind) are one choice, standing for the current mode if that's
# among them, else a preferred one, else the first, so every choice maps to
# exactly one mode. note is "current" or empty.
rates_for_mode() {
	output_modes "$1" | awk -F'|' -v size="$2" '
        $2 != size { next }
        !($3 in first) { order[n++] = $3; first[$3] = $1 }
        $5 && !($3 in pref) { pref[$3] = $1 }
        $4 { cur[$3] = $1 }
        END {
            for (i = 0; i < n; i++) {
                r = order[i]
                if (r in cur) print r "|" cur[r] "|current"
                else print r "|" ((r in pref) ? pref[r] : first[r]) "|"
            }
        }'
}

# The XID of output $1's plain (not interlaced or double-scan) mode of size
# $2 whose rate is nearest its current one, preferring the current mode on
# a tie. Empty if it has no plain mode of that size.
closest_mode() {
	output_modes "$1" | awk -F'|' -v size="$2" '
        { i = n++; xid[i] = $1; sz[i] = $2; rate[i] = $3; cur[i] = $4 }
        $4 { now = $3 + 0 }
        END {
            for (i = 0; i < n; i++) {
                if (sz[i] != size || rate[i] !~ /^[0-9.]+$/) continue
                d = rate[i] - now
                if (d < 0) d = -d
                if (best == "" || d < bestd || (d == bestd && cur[i])) { best = xid[i]; bestd = d }
            }
            if (best != "") print best
        }'
}

# Run an xrandr mutation and surface failures instead of swallowing them.
# xrandr commonly rejects mode/rate/position combinations a driver doesn't
# actually support (or a layout exceeding the virtual screen's reported
# maximum) with a nonzero exit and a stderr message; a bare call here would
# otherwise fail silently from the whiptail UI's perspective.
# The failure msgbox is lib/tui.sh's run_or_report. The cached xrandr state
# is marked stale here, in the caller's shell, whether or not the call
# succeeds: even a failed one may have changed something.
run_xrandr() {
	XR_LOADED=0
	run_or_report "xrandr failed" xrandr "$@"
}

# The geometry (WxH+X+Y) an output shows on screen, empty while it's off.
# WxH is the area it scans out, after rotation and scaling.
output_geom() { xrandr_outputs | awk -F'|' -v n="$1" '$1==n {print $4}'; }

# The display that's on with its right edge furthest right, empty if none.
rightmost_output() {
	active_outputs | awk -F'|' '{
            split($4, g, /[x+]/)
            if (best == "" || g[1] + g[3] > edge) { best = $1; edge = g[1] + g[3] }
        } END { if (best != "") print best }'
}

# Turn on an output that's off, at its preferred mode (--auto), to the right
# of the rightmost display that's on. With no relation, xrandr puts a newly
# enabled output at +0+0, on top of whatever is there. The rightmost display
# rather than the primary, because xrandr doesn't move other outputs aside:
# "right of the primary" would land on any display already to its right.
# Every action that can turn an output on goes through here. Any arguments
# after the output replace --auto, e.g. "--mode 0x4b" for a picked mode.
enable_output() {
	local out="$1" anchor
	shift
	[ "$#" -gt 0 ] || set -- --auto
	# After an earlier change (detect turning on several displays) the cache
	# is stale. Reload it here, in the main shell, so the probe is kept for
	# whatever reads next instead of made and thrown away in the subshell.
	[ "$XR_LOADED" -eq 1 ] || xr_load
	anchor=$(rightmost_output)
	if [ -n "$anchor" ]; then
		run_xrandr --output "$out" "$@" --right-of "$anchor"
	else
		run_xrandr --output "$out" "$@"
	fi
}

# Whether an output's transform (the "Transform:" matrix of xrandr --verbose)
# is the identity, i.e. it isn't scaled. Also true when no matrix can be
# read, so nothing is cleared on a guess. An output that's off always reads
# as the identity, and xrandr turns one on with that, so enable_output never
# has a transform to clear.
transform_is_identity() {
	xr_state | awk -v out="$1" '
        /^[^ \t]+ (connected|disconnected)/ { capture = ($1 == out); next }
        capture && /Transform:/ { rows = 3; sub(/.*Transform:/, "") }
        rows > 0 { for (i = 1; i <= NF; i++) m[n++] = $i + 0; rows-- }
        END {
            if (n != 9) exit 0
            for (i = 0; i < 9; i++) if (m[i] != (i % 4 == 0)) exit 1
        }'
}

# Sets the caller's reset_args to the option that clears $1's transform, or
# to nothing. The transform may be a scale an earlier mirror left or the
# user's own (HiDPI scaling, say), so ask before clearing it. --transform
# none gives "a unit matrix without filter" (xrandr(1)), the state an output
# starts in; --scale 1x1 would also pin the filter to nearest.
transform_reset_args() {
	reset_args=()
	transform_is_identity "$1" && return 0
	if wt --yesno "$1 is scaled or transformed, by an earlier mirror or a setting made outside this tool.\n\nClear that as well?" 11 64; then
		reset_args=(--transform none)
	fi
	return 0
}

# --- pickers ------------------------------------------------------------

# Pickers run inside $(...), so any msgbox here relies on wt drawing it on
# /dev/tty (see wt above); never call whiptail directly from one.

# Build a whiptail --menu output picker. source_fn is one of
# connected_outputs / active_outputs.
pick_output() {
	local prompt="$1" source_fn="$2"
	local items=() name status primary geom desc
	while IFS='|' read -r name status primary geom; do
		[ -z "$name" ] && continue
		desc="$status"
		[ "$primary" = yes ] && desc="$desc, primary"
		[ -n "$geom" ] && desc="$desc, $geom"
		items+=("$name" "$desc")
	done < <("$source_fn")
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No matching displays found." 8 50
		return 1
	fi
	wt --menu "$prompt" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

pick_resolution() {
	local out="$1"
	local items=() res
	while IFS= read -r res; do
		[ -z "$res" ] && continue
		items+=("$res" "")
	done < <(resolutions_for_output "$out")
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No modes reported for $out." 8 50
		return 1
	fi
	wt --menu "Resolution for $out" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

# Prints the chosen RATE choice (see rates_for_mode), e.g. "60.00" or, for
# an interlaced mode, "60.00i".
pick_rate() {
	local out="$1" size="$2"
	local items=() rate xid note desc
	while IFS='|' read -r rate xid note; do
		[ -z "$rate" ] && continue
		desc="Hz"
		case "$rate" in *i*) desc+=", interlaced" ;; esac
		case "$rate" in *d*) desc+=", double scan" ;; esac
		[ -z "$note" ] || desc+=" ($note)"
		items+=("$rate" "$desc")
	done < <(rates_for_mode "$out" "$size")
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No refresh rates reported for $out $size." 8 50
		return 1
	fi
	wt --menu "Refresh rate for $out $size" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

# --- actions --------------------------------------------------------------

action_show_layout() {
	local tmp
	tmp=$(mktemp) || die "mktemp failed"
	# Deliberately not using `trap ... RETURN` here: that trap is global,
	# not scoped to this function invocation, so it would keep firing on
	# every later function's return too, referencing a $tmp that's already
	# gone out of scope and crashing the whole script under `set -u`.
	xrandr --query >"$tmp"
	wt --textbox "$tmp" 0 0
	rm -f "$tmp"
}

# Connected but off covers a display that was just plugged in and one that
# was turned off on purpose, so ask about each before turning it on.
action_detect() {
	local name status primary geom msg="" off=() on=() failed=() left=()
	# Collect the list before any dialog runs, so whiptail never inherits
	# the process substitution as its stdin.
	while IFS='|' read -r name status primary geom; do
		if [ "$status" = connected ] && [ -z "$geom" ]; then
			off+=("$name")
		fi
	done < <(xrandr_outputs)
	if [ "${#off[@]}" -eq 0 ]; then
		wt --msgbox "No connected display is turned off." 8 60
		return 0
	fi
	for name in "${off[@]}"; do
		if ! wt --yesno "$name is connected but turned off. It may have just been plugged in, or been turned off on purpose.\n\nTurn it on?" 11 64; then
			left+=("$name")
		elif enable_output "$name"; then
			on+=("$name")
		else
			failed+=("$name")
		fi
	done
	[ "${#on[@]}" -eq 0 ] || msg+="Turned on: ${on[*]}\n"
	[ "${#failed[@]}" -eq 0 ] || msg+="Failed: ${failed[*]}\n"
	[ "${#left[@]}" -eq 0 ] || msg+="Left off: ${left[*]}\n"
	wt --msgbox "$msg" 10 60
}

action_set_mode() {
	local out res rate xid reset_args=()
	out=$(pick_output "Choose a display to configure" connected_outputs) || return 0
	[ -z "$out" ] && return 0
	res=$(pick_resolution "$out") || return 0
	[ -z "$res" ] && return 0
	rate=$(pick_rate "$out" "$res") || return 0
	[ -z "$rate" ] && return 0
	# Set by XID. "--mode NAME --rate R" makes xrandr take the first mode of
	# that name whose rate is nearest R, which needn't be the one picked when
	# two modes share a name and a rounded rate, and a size's modes can go
	# by other names entirely.
	xid=$(rates_for_mode "$out" "$res" | awk -F'|' -v r="$rate" '!found && $1 == r { print $2; found = 1 }')
	if [ -z "$xid" ]; then
		wt --msgbox "$out no longer reports a $res mode at $rate Hz." 8 60
		return 0
	fi
	# A mode on an output that's off turns it on. Ask first, as detect does
	# (it may be off on purpose), then place it as enable_output does rather
	# than at +0+0 on top of another display. It has no transform to clear.
	if [ -z "$(output_geom "$out")" ]; then
		wt --yesno "$out is turned off. Turn it on at $res, $rate Hz, to the right of the displays that are on?" 10 64 || return 0
		enable_output "$out" --mode "$xid"
		return
	fi
	# xrandr keeps a transform across a mode change, and a mirror's scale
	# is sized for the old mode.
	transform_reset_args "$out"
	run_xrandr --output "$out" --mode "$xid" "${reset_args[@]}"
}

action_set_primary() {
	local out
	out=$(pick_output "Choose the primary display" active_outputs) || return 0
	[ -z "$out" ] && return 0
	run_xrandr --output "$out" --primary
}

action_position() {
	local out ref choice reset_args=()
	out=$(pick_output "Move which display?" active_outputs) || return 0
	[ -z "$out" ] && return 0
	ref=$(pick_output "...relative to which display?" active_outputs) || return 0
	[ -z "$ref" ] && return 0
	if [ "$out" = "$ref" ]; then
		wt --msgbox "Pick two different displays." 8 50
		return 0
	fi
	choice=$(wt --menu "Position $out relative to $ref" 0 0 0 \
		"left-of" "$out is to the left of $ref" \
		"right-of" "$out is to the right of $ref" \
		"above" "$out is above $ref" \
		"below" "$out is below $ref" \
		3>&1 1>&2 2>&3) || return 0
	# No --auto: both outputs are already on, and --auto would reset $out to
	# its preferred mode and rate. Without a mode option xrandr keeps the
	# current one, and its transform too, so moving a display out of a
	# scaled mirror would leave it stretched unless that's cleared.
	transform_reset_args "$out"
	run_xrandr --output "$out" "--$choice" "$ref" "${reset_args[@]}"
}

action_mirror() {
	local out ref size xid args=()
	out=$(pick_output "Mirror which display?" active_outputs) || return 0
	[ -z "$out" ] && return 0
	ref=$(pick_output "...onto which display? (same image as)" active_outputs) || return 0
	[ -z "$ref" ] && return 0
	if [ "$out" = "$ref" ]; then
		wt --msgbox "Pick two different displays." 8 50
		return 0
	fi
	# $out has to show the area $ref shows. --auto would put it on its own
	# preferred mode instead, so the two would show different areas. If $out
	# has a mode of that size (by its real size, whatever it's named), switch
	# to the one nearest its current rate, by XID, and clear any transform
	# without asking: a mirror has to be 1:1, and a leftover scale would
	# stretch it. Only otherwise
	# keep $out's mode and scale $ref's area onto it with --scale-from, which
	# replaces any transform. Rotation isn't copied, so a rotated $ref gets
	# stretched to fit.
	size=$(output_geom "$ref")
	size=${size%%+*}
	if [ -z "$size" ]; then
		wt --msgbox "Couldn't read the size of $ref." 8 50
		return 0
	fi
	xid=$(closest_mode "$out" "$size")
	if [ -n "$xid" ]; then
		args=(--mode "$xid")
		transform_is_identity "$out" || args+=(--transform none)
	else
		args=(--scale-from "$size")
	fi
	run_xrandr --output "$out" --same-as "$ref" "${args[@]}"
}

action_toggle() {
	local out geom
	out=$(pick_output "Turn a display on or off" connected_outputs) || return 0
	[ -z "$out" ] && return 0
	geom=$(output_geom "$out")
	if [ -n "$geom" ]; then
		# Turning off the last display leaves a black screen, and getting
		# the picture back means typing blind.
		if [ "$(active_outputs | awk 'END { print NR }')" -le 1 ]; then
			wt --msgbox "$out is the only display that's on, so it stays on. Turn another display on first." 9 60
			return 0
		fi
		wt --yesno "$out is currently on. Turn it off?" 8 50 || return 0
		run_xrandr --output "$out" --off
	else
		enable_output "$out"
	fi
}

action_rotate() {
	local out rot
	out=$(pick_output "Rotate which display?" active_outputs) || return 0
	[ -z "$out" ] && return 0
	rot=$(wt --menu "Rotation for $out" 0 0 0 \
		"normal" "No rotation" \
		"left" "90 degrees counter-clockwise" \
		"right" "90 degrees clockwise" \
		"inverted" "180 degrees" \
		3>&1 1>&2 2>&3) || return 0
	run_xrandr --output "$out" --rotate "$rot"
}

main_menu() {
	local choice
	while true; do
		choice=$(wt --menu "Display management" 0 0 0 \
			"detect" "Turn on connected displays that are off" \
			"layout" "Show current layout (xrandr --query)" \
			"mode" "Set resolution & refresh rate" \
			"primary" "Set primary display" \
			"position" "Position a display relative to another" \
			"mirror" "Mirror one display onto another" \
			"toggle" "Turn a display on/off" \
			"rotate" "Rotate a display" \
			"quit" "Exit" \
			3>&1 1>&2 2>&3) || break
		# One probe per action, fresh each time round (see xr_load). The
		# layout view shows its own xrandr --query instead.
		case "$choice" in
		layout | quit | "") ;;
		*) xr_load ;;
		esac
		case "$choice" in
		detect) action_detect ;;
		layout) action_show_layout ;;
		mode) action_set_mode ;;
		primary) action_set_primary ;;
		position) action_position ;;
		mirror) action_mirror ;;
		toggle) action_toggle ;;
		rotate) action_rotate ;;
		quit | "") break ;;
		esac
	done
}

main() {
	# mktemp and rm are for the layout view. dirname and readlink have to
	# work before the lib is even found, so a system without them stops at
	# the "lib/tui.sh is missing" check above.
	require_tools whiptail xrandr awk mktemp rm
	[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && die "this script drives xrandr and needs an X11 session (Wayland detected)"
	xrandr --query >/dev/null 2>&1 || die "xrandr --query failed; is an X server running?"
	main_menu
}

main "$@"
