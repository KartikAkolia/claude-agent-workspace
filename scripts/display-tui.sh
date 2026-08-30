#!/usr/bin/env bash
# Whiptail TUI for granular X11 display management: resolution, refresh
# rate, layout/position, mirroring, rotation, and detecting newly plugged
# displays. Scratches an itch arandr doesn't: arandr has no refresh-rate
# control at all, and its layout editor is mouse-only.
#
# Drives xrandr directly; needs an X11 session. Not applicable under
# Wayland (no xrandr equivalent there worth wrapping the same way).
set -uo pipefail
readonly PROG="${0##*/}"

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

require_tools() {
	local t missing=()
	for t in whiptail xrandr awk; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	[ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# whiptail wrapper. This whiptail build (newt, no dialog compat layer) has
# no top-level --height/--width option — only --menu/--msgbox/etc. accept
# height/width, positionally, after the text. Every call site below passes
# "0 0[ 0]" for those, which newt auto-sizes to fit the content; do not add
# --height/--width flags here (see scripts/audio-tui.sh for how that broke
# rendering entirely the first time around).
wt() {
	whiptail --backtitle "$PROG" "$@"
}

# --- xrandr parsing ---------------------------------------------------

# One line per output: name|connected|primary(yes/no)|geometry(WxH+X+Y or empty)
# geometry is empty for a connected-but-disabled output (e.g. a laptop
# panel turned off while docked), same as for a disconnected one.
xrandr_outputs() {
	xrandr --query | awk '
        /^[^ ]+ (connected|disconnected)/ {
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

# Raw mode/rate lines belonging to one output, e.g.
#   "   1920x1080     60.00 + 180.00*  165.00 ..."
# '+' marks the currently-set resolution, '*' (glued to a rate, no space)
# marks the currently-set refresh rate.
modes_for_output() {
	local out="$1"
	xrandr --query | awk -v out="$out" '
        /^[^ ]+ (connected|disconnected)/ { capture = ($1 == out); next }
        capture && /^[[:space:]]+[0-9]+x[0-9]+/ { print }'
}

resolutions_for_output() { modes_for_output "$1" | awk '{print $1}'; }

# Run an xrandr mutation and surface failures instead of swallowing them.
# xrandr commonly rejects mode/rate/position combinations a driver doesn't
# actually support (or a layout exceeding the virtual screen's reported
# maximum) with a nonzero exit and a stderr message; a bare call here would
# otherwise fail silently from the whiptail UI's perspective.
run_xrandr() {
	local err status
	err=$(xrandr "$@" 2>&1 >/dev/null)
	status=$?
	if [ "$status" -ne 0 ]; then
		wt --msgbox "xrandr failed:\n${err:-exit status $status}" 12 70
		return 1
	fi
	return 0
}

rates_for_mode() {
	local out="$1" mode="$2"
	modes_for_output "$out" | awk -v mode="$mode" '$1==mode { $1=""; print }' |
		tr -s ' ' '\n' |
		grep -E '^[0-9]+\.[0-9]+\*?$' |
		sed -E 's/\*$//'
}

# --- pickers ------------------------------------------------------------

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

pick_rate() {
	local out="$1" mode="$2"
	local items=() rate
	while IFS= read -r rate; do
		[ -z "$rate" ] && continue
		items+=("$rate" "Hz")
	done < <(rates_for_mode "$out" "$mode")
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No refresh rates reported for $out $mode." 8 50
		return 1
	fi
	wt --menu "Refresh rate for $out $mode" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
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

action_detect() {
	local name status primary geom found=0
	while IFS='|' read -r name status primary geom; do
		if [ "$status" = connected ] && [ -z "$geom" ]; then
			run_xrandr --output "$name" --auto
			found=1
		fi
	done < <(xrandr_outputs)
	if [ "$found" -eq 0 ]; then
		wt --msgbox "No newly connected, unconfigured displays found." 8 60
	else
		wt --msgbox "Auto-configured newly detected display(s)." 8 60
	fi
}

action_set_mode() {
	local out res rate
	out=$(pick_output "Choose a display to configure" connected_outputs) || return 0
	[ -z "$out" ] && return 0
	res=$(pick_resolution "$out") || return 0
	[ -z "$res" ] && return 0
	rate=$(pick_rate "$out" "$res") || return 0
	[ -z "$rate" ] && return 0
	run_xrandr --output "$out" --mode "$res" --rate "$rate"
}

action_set_primary() {
	local out
	out=$(pick_output "Choose the primary display" active_outputs) || return 0
	[ -z "$out" ] && return 0
	run_xrandr --output "$out" --primary
}

action_position() {
	local out ref choice
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
	run_xrandr --output "$out" "--$choice" "$ref" --auto
}

action_mirror() {
	local out ref
	out=$(pick_output "Mirror which display?" active_outputs) || return 0
	[ -z "$out" ] && return 0
	ref=$(pick_output "...onto which display? (same image as)" active_outputs) || return 0
	[ -z "$ref" ] && return 0
	if [ "$out" = "$ref" ]; then
		wt --msgbox "Pick two different displays." 8 50
		return 0
	fi
	run_xrandr --output "$out" --same-as "$ref" --auto
}

action_toggle() {
	local out geom
	out=$(pick_output "Turn a display on or off" connected_outputs) || return 0
	[ -z "$out" ] && return 0
	geom=$(xrandr_outputs | awk -F'|' -v n="$out" '$1==n {print $4}')
	if [ -n "$geom" ]; then
		wt --yesno "$out is currently on. Turn it off?" 8 50 || return 0
		run_xrandr --output "$out" --off
	else
		run_xrandr --output "$out" --auto
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
			"detect" "Detect / auto-configure newly connected displays" \
			"layout" "Show current layout (xrandr --query)" \
			"mode" "Set resolution & refresh rate" \
			"primary" "Set primary display" \
			"position" "Position a display relative to another" \
			"mirror" "Mirror one display onto another" \
			"toggle" "Turn a display on/off" \
			"rotate" "Rotate a display" \
			"quit" "Exit" \
			3>&1 1>&2 2>&3) || break
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
	require_tools
	[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && die "this script drives xrandr and needs an X11 session (Wayland detected)"
	xrandr --query >/dev/null 2>&1 || die "xrandr --query failed; is an X server running?"
	main_menu
}

main "$@"
