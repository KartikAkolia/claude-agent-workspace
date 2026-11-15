#!/usr/bin/env bash
# display-tui.sh — whiptail front end for xrandr on X11: resolution, refresh
# rate, layout, mirroring, rotation, and turning displays on or off.
# Docs: docs/desktop-tuis.md
set -uo pipefail

tui_lib="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/tui.sh"
if [ ! -r "$tui_lib" ]; then
	printf 'error: %s is missing; run %s from the repo checkout, or keep scripts/lib/ beside it\n' "$tui_lib" "${0##*/}" >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$tui_lib"

# One xrandr probe per action: main_menu's xr_load runs in the main shell, so $(...) pickers share it.
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

xr_state() {
	[ "$XR_LOADED" -eq 1 ] || xr_load
	printf '%s\n' "$XR_STATE"
}

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

output_modes() {
	[ "$XR_LOADED" -eq 1 ] || xr_load
	xr_state | awk -v out="$1" -v loose="$XR_LOOSE" '
        BEGIN { n = split(loose, l, " "); for (i = 1; i <= n; i++) skip[l[i]] = 1 }
        /^[^ \t]+ (connected|disconnected)/ { capture = ($1 == out); next }
        !capture { next }
        /^  [^ ]/ && match($0, /\(0x[0-9a-fA-F]+\)/) {
            xid = substr($0, RSTART + 1, RLENGTH - 2)
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

resolutions_for_output() { output_modes "$1" | awk -F'|' '!seen[$2]++ { print $2 }'; }

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

run_xrandr() {
	XR_LOADED=0
	run_or_report "xrandr failed" xrandr "$@"
}

output_geom() { xrandr_outputs | awk -F'|' -v n="$1" '$1==n {print $4}'; }

rightmost_output() {
	active_outputs | awk -F'|' '{
            split($4, g, /[x+]/)
            if (best == "" || g[1] + g[3] > edge) { best = $1; edge = g[1] + g[3] }
        } END { if (best != "") print best }'
}

enable_output() {
	local out="$1" anchor
	shift
	[ "$#" -gt 0 ] || set -- --auto
	[ "$XR_LOADED" -eq 1 ] || xr_load
	anchor=$(rightmost_output)
	[ -z "$anchor" ] || set -- "$@" --right-of "$anchor"
	run_xrandr --output "$out" "$@"
}

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

transform_reset_args() {
	reset_args=()
	transform_is_identity "$1" && return 0
	wt --yesno "$1 is scaled or transformed, by an earlier mirror or a setting made outside this tool.\n\nClear that as well?" 11 64 && reset_args=(--transform none)
	return 0
}

pick_output() {
	local items=() name status primary geom desc
	while IFS='|' read -r name status primary geom; do
		[ -z "$name" ] && continue
		desc="$status"
		[ "$primary" = yes ] && desc="$desc, primary"
		[ -n "$geom" ] && desc="$desc, $geom"
		items+=("$name" "$desc")
	done < <("$2")
	pick_menu "$1" "No matching displays found." "${items[@]}"
}

pick_two() {
	local -n _pick_out=$1 _pick_ref=$2
	_pick_out=$(pick_output "$3" active_outputs) || return 1
	_pick_ref=$(pick_output "$4" active_outputs) || return 1
	[ "$_pick_out" != "$_pick_ref" ] && return 0
	wt --msgbox "Pick two different displays." 8 50
	return 1
}

pick_resolution() {
	local items=() res
	while IFS= read -r res; do
		[ -z "$res" ] && continue
		items+=("$res" "")
	done < <(resolutions_for_output "$1")
	pick_menu "Resolution for $1" "No modes reported for $1." "${items[@]}"
}

pick_rate() {
	local out="$1" size="$2" items=() rate xid note desc
	while IFS='|' read -r rate xid note; do
		[ -z "$rate" ] && continue
		desc="Hz"
		case "$rate" in *i*) desc+=", interlaced" ;; esac
		case "$rate" in *d*) desc+=", double scan" ;; esac
		[ -z "$note" ] || desc+=" ($note)"
		items+=("$rate" "$desc")
	done < <(rates_for_mode "$out" "$size")
	pick_menu "Refresh rate for $out $size" "No refresh rates reported for $out $size." "${items[@]}"
}

action_show_layout() {
	local tmp
	tmp=$(mktemp) || die "mktemp failed"
	xrandr --query >"$tmp"
	wt --textbox "$tmp" 0 0
	rm -f "$tmp"
}

action_detect() {
	local name msg="" off=() on=() failed=() left=()
	mapfile -t off < <(connected_outputs | awk -F'|' '$4 == "" { print $1 }')
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
	res=$(pick_resolution "$out") || return 0
	rate=$(pick_rate "$out" "$res") || return 0
	xid=$(rates_for_mode "$out" "$res" | awk -F'|' -v r="$rate" '!found && $1 == r { print $2; found = 1 }')
	if [ -z "$xid" ]; then
		wt --msgbox "$out no longer reports a $res mode at $rate Hz." 8 60
		return 0
	fi
	if [ -z "$(output_geom "$out")" ]; then
		wt --yesno "$out is turned off. Turn it on at $res, $rate Hz, to the right of the displays that are on?" 10 64 || return 0
		enable_output "$out" --mode "$xid"
		return
	fi
	transform_reset_args "$out"
	run_xrandr --output "$out" --mode "$xid" "${reset_args[@]}"
}

action_set_primary() {
	local out
	out=$(pick_output "Choose the primary display" active_outputs) || return 0
	run_xrandr --output "$out" --primary
}

action_position() {
	local out ref choice reset_args=()
	pick_two out ref "Move which display?" "...relative to which display?" || return 0
	choice=$(wt --menu "Position $out relative to $ref" 0 0 0 \
		"left-of" "$out is to the left of $ref" \
		"right-of" "$out is to the right of $ref" \
		"above" "$out is above $ref" \
		"below" "$out is below $ref" \
		3>&1 1>&2 2>&3) || return 0
	transform_reset_args "$out"
	run_xrandr --output "$out" "--$choice" "$ref" "${reset_args[@]}"
}

action_mirror() {
	local out ref size xid args=()
	pick_two out ref "Mirror which display?" "...onto which display? (same image as)" || return 0
	size=$(output_geom "$ref")
	size=${size%%+*}
	if [ -z "$size" ]; then
		wt --msgbox "Couldn't read the size of $ref." 8 50
		return 0
	fi
	xid=$(closest_mode "$out" "$size")
	args=(--scale-from "$size")
	if [ -n "$xid" ]; then
		args=(--mode "$xid")
		transform_is_identity "$out" || args+=(--transform none)
	fi
	run_xrandr --output "$out" --same-as "$ref" "${args[@]}"
}

action_toggle() {
	local out
	out=$(pick_output "Turn a display on or off" connected_outputs) || return 0
	if [ -z "$(output_geom "$out")" ]; then
		enable_output "$out"
		return
	fi
	if [ "$(active_outputs | awk 'END { print NR }')" -le 1 ]; then
		wt --msgbox "$out is the only display that's on, so it stays on. Turn another display on first." 9 60
		return 0
	fi
	wt --yesno "$out is currently on. Turn it off?" 8 50 || return 0
	run_xrandr --output "$out" --off
}

action_rotate() {
	local out rot
	out=$(pick_output "Rotate which display?" active_outputs) || return 0
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
	require_tools whiptail xrandr awk mktemp rm
	[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && die "this script drives xrandr and needs an X11 session (Wayland detected)"
	xrandr --query >/dev/null 2>&1 || die "xrandr --query failed; is an X server running?"
	main_menu
}

main "$@"
