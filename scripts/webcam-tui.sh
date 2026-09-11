#!/usr/bin/env bash
# webcam-tui.sh — whiptail front end for v4l2-ctl camera controls (exposure,
# focus, and everything else a UVC webcam exposes), for the same reason
# audio-tui.sh/display-tui.sh exist: a keyboard-driven, mouse-optional (dwm)
# way to do what a GUI (guvcview) would otherwise be needed for.
#
# Backend: `v4l2-ctl -d <dev> --list-ctrls-menus` for introspection (one
# pass gets both a control's current value AND its menu-type enum options,
# unlike --list-ctrls alone) and `v4l2-ctl -d <dev> --set-ctrl=...` for
# changes. No jq/json here — v4l2-ctl has no structured-output mode, so
# parsing is plain awk/grep/bash-regex over its fixed-width text.
#
# Control names are NOT hardcoded to "exposure_auto"/"focus_auto": UVC
# drivers disagree on naming (this host's own webcams report
# auto_exposure/focus_automatic_continuous instead — confirmed live on
# /dev/video0 and /dev/video2 while writing this). resolve_ctrl_name()
# tries a short candidate list per logical control instead of assuming one
# name; "Browse & edit all controls" works off whatever names a driver
# actually reports, unconditionally.
#
# Deliberately not using `set -e`: whiptail's own exit code (1/255 on
# Cancel/Esc) is normal control flow here, checked explicitly at each menu,
# not something a blanket -e should abort the whole TUI over.
set -uo pipefail

readonly PROG="${0##*/}"
readonly PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/webcam-tui/profiles"

# ---------------------------------------------------------------------------
# Setup / preflight
# ---------------------------------------------------------------------------

require_tools() {
	local missing=() cmd
	for cmd in whiptail v4l2-ctl awk grep; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		printf 'error: missing required tool(s): %s\n' "${missing[*]}" >&2
		exit 1
	fi
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
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

# ---------------------------------------------------------------------------
# Device discovery — `v4l2-ctl --list-devices` lists every /dev/videoN node
# per physical camera, including metadata-only nodes (e.g. the UVC metadata
# stream a webcam exposes alongside its actual capture node). Only nodes
# whose *own* Device Caps (not the aggregate Capabilities line, which lists
# a sibling node's caps too) include Video Capture are offered.
# ---------------------------------------------------------------------------

is_capture_node() {
	local dev="$1"
	# The "Device Caps" line and its indented capability list are themselves
	# tab-indented one level (v4l2-ctl -D's whole output is), so the start
	# pattern has to tolerate that instead of anchoring to column 0.
	v4l2-ctl -d "$dev" -D 2>/dev/null | awk '
		/^[[:space:]]*Device Caps/ { found=1; next }
		found && /^[^[:space:]]/ { found=0 }
		found && /Video Capture/ { print; exit }
	' | grep -q .
}

# Emits TSV: node<TAB>label, one line per capture-capable node.
list_capture_devices() {
	local name="" line node
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		if [[ "$line" =~ ^[[:space:]]+(/dev/.+)$ ]]; then
			node="${BASH_REMATCH[1]}"
			is_capture_node "$node" && printf '%s\t%s\n' "$node" "$name"
		else
			name="${line%:}"
		fi
	done < <(v4l2-ctl --list-devices 2>/dev/null)
}

pick_device() {
	local title="$1" menu_args=() node name
	while IFS=$'\t' read -r node name; do
		[ -z "$node" ] && continue
		menu_args+=("$node" "$name ($node)")
	done < <(list_capture_devices)

	[ "${#menu_args[@]}" -eq 0 ] && {
		wt --msgbox "No capture-capable video devices found." 8 60
		return 1
	}
	wt --menu "$title" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

# ---------------------------------------------------------------------------
# Control introspection — thin parsers over `--list-ctrls-menus` text.
# ---------------------------------------------------------------------------

list_ctrls_raw() { v4l2-ctl -d "$1" --list-ctrls-menus 2>/dev/null; }

# One control name per line, in the order v4l2-ctl reports them.
ctrl_names() {
	list_ctrls_raw "$1" | awk '$2 ~ /^0x[0-9a-fA-F]+$/ { print $1 }'
}

ctrl_line() {
	local dev="$1" name="$2"
	list_ctrls_raw "$dev" | awk -v n="$name" '$1==n && $2 ~ /^0x[0-9a-fA-F]+$/'
}

# Menu-type controls only: the "N: Description" lines directly under that
# control's header line, up to the next control/section header.
ctrl_menu_items() {
	local dev="$1" name="$2"
	list_ctrls_raw "$dev" | awk -v n="$name" '
		$1==n && $2 ~ /^0x[0-9a-fA-F]+$/ { grab=1; next }
		grab && $0 ~ /^[[:space:]]+[0-9]+:/ { print; next }
		grab { grab=0 }
	'
}

# Sets CTRL_TYPE/CTRL_MIN/CTRL_MAX/CTRL_STEP/CTRL_DEFAULT/CTRL_VALUE/
# CTRL_DESC/CTRL_INACTIVE from $2's current line on $1. Returns 1 if $2
# isn't a control on $1 at all.
parse_ctrl() {
	local dev="$1" name="$2" line
	line=$(ctrl_line "$dev" "$name")
	[ -z "$line" ] && return 1

	[[ "$line" =~ \(([a-z0-9]+)\) ]] && CTRL_TYPE="${BASH_REMATCH[1]}" || CTRL_TYPE=""
	CTRL_MIN=$(grep -o 'min=-\?[0-9x0-9a-fA-F]*' <<<"$line" | head -1 | cut -d= -f2)
	CTRL_MAX=$(grep -o 'max=[^ ]*' <<<"$line" | head -1 | cut -d= -f2)
	CTRL_STEP=$(grep -o 'step=[^ ]*' <<<"$line" | head -1 | cut -d= -f2)
	CTRL_DEFAULT=$(grep -o 'default=[^ ]*' <<<"$line" | head -1 | cut -d= -f2)
	CTRL_VALUE=$(grep -o 'value=[^ ]*' <<<"$line" | head -1 | cut -d= -f2)
	CTRL_INACTIVE=0
	[[ "$line" == *flags=*inactive* ]] && CTRL_INACTIVE=1
	CTRL_DESC=""
	[ "$CTRL_TYPE" = menu ] && [[ "$line" =~ value=[^\ ]+\ \((.*)\)$ ]] && CTRL_DESC="${BASH_REMATCH[1]}"
	return 0
}

# Tries each candidate name in turn against $1's actual control list,
# returns the first one that exists (empty + nonzero if none do). Exists
# because UVC drivers don't agree on names for the same logical control —
# see the file header comment.
resolve_ctrl_name() {
	local dev="$1" all cand
	shift
	all=$(ctrl_names "$dev")
	for cand in "$@"; do
		grep -qx "$cand" <<<"$all" && {
			printf '%s' "$cand"
			return 0
		}
	done
	return 1
}

# ---------------------------------------------------------------------------
# Applying changes
# ---------------------------------------------------------------------------

# Quiet apply, for batch callers (profile load, reset-to-defaults) that
# report one summary at the end instead of a msgbox per control.
set_ctrl() {
	local dev="$1" name="$2" val="$3"
	v4l2-ctl -d "$dev" --set-ctrl="${name}=${val}" >/dev/null 2>&1
}

# Same, but surfaces a failure interactively — for the single explicit
# edits a user makes from a menu, where silence would look like a no-op.
run_v4l2_set() {
	local dev="$1" name="$2" val="$3" err status
	err=$(v4l2-ctl -d "$dev" --set-ctrl="${name}=${val}" 2>&1 >/dev/null)
	status=$?
	[ "$status" -ne 0 ] && wt --msgbox "v4l2-ctl failed setting $name=$val:\n${err:-exit status $status}" 12 70
	return "$status"
}

# One control, editor appropriate to its type. Returns 1 on cancel/no-op.
edit_ctrl() {
	local dev="$1" name="$2"
	parse_ctrl "$dev" "$name" || {
		wt --msgbox "Could not read $name on $dev." 8 50
		return 1
	}

	local hint=""
	[ "$CTRL_INACTIVE" -eq 1 ] && hint=" (currently inactive/read-only on this driver — change may be a no-op)"

	case "$CTRL_TYPE" in
	bool)
		local new
		new=$([ "$CTRL_VALUE" = 1 ] && echo 0 || echo 1)
		wt --yesno "$name is currently $CTRL_VALUE.$hint\n\nToggle to $new?" 10 60 || return 1
		run_v4l2_set "$dev" "$name" "$new"
		;;
	menu)
		local items=() line idx label
		while IFS= read -r line; do
			[[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*)$ ]] || continue
			idx="${BASH_REMATCH[1]}"
			label="${BASH_REMATCH[2]}"
			[ "$idx" = "$CTRL_VALUE" ] && label="$label (current)"
			items+=("$idx" "$label")
		done < <(ctrl_menu_items "$dev" "$name")
		[ "${#items[@]}" -eq 0 ] && {
			wt --msgbox "No menu items reported for $name." 8 50
			return 1
		}
		local choice
		choice=$(wt --menu "$name$hint" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
		[ -z "$choice" ] && return 1
		run_v4l2_set "$dev" "$name" "$choice"
		;;
	int | int64)
		local val
		val=$(wt --inputbox "$name (min=$CTRL_MIN max=$CTRL_MAX step=${CTRL_STEP:-1}, default=$CTRL_DEFAULT).$hint" 10 70 "$CTRL_VALUE" 3>&1 1>&2 2>&3) || return 1
		[[ "$val" =~ ^-?[0-9]+$ ]] || {
			wt --msgbox "Not a number: $val" 6 40
			return 1
		}
		if [ "$val" -lt "$CTRL_MIN" ] || [ "$val" -gt "$CTRL_MAX" ]; then
			wt --msgbox "$val is outside $name's range ($CTRL_MIN-$CTRL_MAX)." 8 50
			return 1
		fi
		run_v4l2_set "$dev" "$name" "$val"
		;;
	bitmask | string | rect | *)
		wt --msgbox "$name is a $CTRL_TYPE control — not editable from this menu yet.\nUse: v4l2-ctl -d $dev --set-ctrl=$name=<value>" 10 70
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_show_info() {
	local dev
	dev=$(pick_device "Choose a camera") || return 0
	[ -z "$dev" ] && return 0

	local tmp
	tmp=$(mktemp) || die "mktemp failed"
	# Deliberately not using `trap ... RETURN` here: see display-tui.sh's
	# action_show_layout for why that trap scoping doesn't work under set -u.
	{
		v4l2-ctl -d "$dev" -D
		printf '\n'
		v4l2-ctl -d "$dev" --list-ctrls-menus
	} >"$tmp" 2>&1
	wt --textbox "$tmp" 0 0
	rm -f "$tmp"
}

# Browse every control the driver reports and edit any of them, one at a
# time, re-reading values after each edit — same "pick device once, loop a
# submenu" shape as audio-tui.sh's action_volume.
action_browse_ctrls() {
	local dev
	dev=$(pick_device "Choose a camera to browse controls") || return 0
	[ -z "$dev" ] && return 0

	while true; do
		local items=() name status
		while IFS= read -r name; do
			[ -z "$name" ] && continue
			parse_ctrl "$dev" "$name"
			status="$CTRL_TYPE=$CTRL_VALUE"
			[ -n "$CTRL_DESC" ] && status="$status ($CTRL_DESC)"
			[ "$CTRL_INACTIVE" -eq 1 ] && status="$status [inactive]"
			items+=("$name" "$status")
		done < <(ctrl_names "$dev")

		[ "${#items[@]}" -eq 0 ] && {
			wt --msgbox "No controls reported for $dev." 8 50
			return 0
		}

		local choice
		choice=$(wt --menu "Controls on $dev" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3) || return 0
		[ -z "$choice" ] && return 0
		edit_ctrl "$dev" "$choice"
	done
}

# The original ask: exposure_auto/focus_auto (or whatever this driver calls
# them) as a quick "stable" vs "auto" toggle, plus direct value entry —
# without needing to hunt for the right control names in the browse menu.
action_exposure_focus() {
	local dev
	dev=$(pick_device "Choose a camera to configure exposure & focus for") || return 0
	[ -z "$dev" ] && return 0

	local exp_auto exp_abs foc_auto foc_abs
	exp_auto=$(resolve_ctrl_name "$dev" exposure_auto auto_exposure) || exp_auto=""
	exp_abs=$(resolve_ctrl_name "$dev" exposure_absolute exposure_time_absolute) || exp_abs=""
	foc_auto=$(resolve_ctrl_name "$dev" focus_auto focus_automatic_continuous) || foc_auto=""
	foc_abs=$(resolve_ctrl_name "$dev" focus_absolute) || foc_abs=""

	if [ -z "$exp_auto$exp_abs$foc_auto$foc_abs" ]; then
		wt --msgbox "$dev doesn't report any exposure/focus controls under the usual names.\nUse 'Browse & edit all controls' instead." 10 70
		return 0
	fi

	while true; do
		local status=""
		[ -n "$exp_auto" ] && {
			parse_ctrl "$dev" "$exp_auto"
			status="$status\nauto-exposure: ${CTRL_DESC:-$CTRL_VALUE}"
		}
		[ -n "$exp_abs" ] && {
			parse_ctrl "$dev" "$exp_abs"
			status="$status\nexposure:      $CTRL_VALUE (range $CTRL_MIN-$CTRL_MAX)"
		}
		[ -n "$foc_auto" ] && {
			parse_ctrl "$dev" "$foc_auto"
			status="$status\nautofocus:     $CTRL_VALUE"
		}
		[ -n "$foc_abs" ] && {
			parse_ctrl "$dev" "$foc_abs"
			status="$status\nfocus:         $CTRL_VALUE (range $CTRL_MIN-$CTRL_MAX)"
		}

		local choice
		choice=$(wt --menu "$dev$status" 0 0 0 \
			"stable" "Manual preset: lock exposure + focus (video calls/streaming)" \
			"auto" "Auto preset: revert to the camera's own auto-hunting" \
			"exposure" "Set exposure value only" \
			"focus" "Set focus value only" \
			"back" "Back to main menu" \
			3>&1 1>&2 2>&3) || return 0

		case "$choice" in
		stable) action_apply_manual_preset "$dev" "$exp_auto" "$exp_abs" "$foc_auto" "$foc_abs" ;;
		auto) action_apply_auto_preset "$dev" "$exp_auto" "$foc_auto" ;;
		exposure)
			if [ -n "$exp_abs" ]; then
				edit_ctrl "$dev" "$exp_abs"
			else
				wt --msgbox "No exposure-value control found on $dev." 6 60
			fi
			;;
		focus)
			if [ -n "$foc_abs" ]; then
				edit_ctrl "$dev" "$foc_abs"
			else
				wt --msgbox "No focus-value control found on $dev." 6 60
			fi
			;;
		back | "") return 0 ;;
		esac
	done
}

action_apply_manual_preset() {
	local dev="$1" exp_auto="$2" exp_abs="$3" foc_auto="$4" foc_abs="$5"

	if [ -n "$exp_auto" ]; then
		local manual_idx
		manual_idx=$(ctrl_menu_items "$dev" "$exp_auto" | grep -i 'manual' | head -1 |
			sed -E 's/^[[:space:]]*([0-9]+):.*/\1/')
		[ -n "$manual_idx" ] && run_v4l2_set "$dev" "$exp_auto" "$manual_idx"
	fi
	if [ -n "$exp_abs" ]; then
		parse_ctrl "$dev" "$exp_abs"
		local val
		val=$(wt --inputbox "Fixed exposure value (min=$CTRL_MIN max=$CTRL_MAX):" 8 60 "$CTRL_VALUE" 3>&1 1>&2 2>&3)
		[[ "${val:-}" =~ ^[0-9]+$ ]] && run_v4l2_set "$dev" "$exp_abs" "$val"
	fi
	[ -n "$foc_auto" ] && run_v4l2_set "$dev" "$foc_auto" 0
	if [ -n "$foc_abs" ]; then
		parse_ctrl "$dev" "$foc_abs"
		local val
		val=$(wt --inputbox "Fixed focus value (min=$CTRL_MIN max=$CTRL_MAX, 0=infinity):" 8 60 "$CTRL_VALUE" 3>&1 1>&2 2>&3)
		[[ "${val:-}" =~ ^[0-9]+$ ]] && run_v4l2_set "$dev" "$foc_abs" "$val"
	fi
	wt --msgbox "Manual preset applied." 6 40
}

action_apply_auto_preset() {
	local dev="$1" exp_auto="$2" foc_auto="$3"

	if [ -n "$exp_auto" ]; then
		local auto_idx
		auto_idx=$(ctrl_menu_items "$dev" "$exp_auto" | grep -iE 'aperture|auto' | head -1 |
			sed -E 's/^[[:space:]]*([0-9]+):.*/\1/')
		[ -n "$auto_idx" ] && run_v4l2_set "$dev" "$exp_auto" "$auto_idx"
	fi
	[ -n "$foc_auto" ] && run_v4l2_set "$dev" "$foc_auto" 1
	wt --msgbox "Auto preset applied." 6 40
}

# Reset every writable control back to the driver-reported default — the
# undo button for anything the actions above changed.
action_reset_defaults() {
	local dev
	dev=$(pick_device "Choose a camera to reset to defaults") || return 0
	[ -z "$dev" ] && return 0
	wt --yesno "Reset every writable control on $dev to its driver default?" 8 60 || return 0

	local name applied=0 skipped=0
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		parse_ctrl "$dev" "$name"
		case "$CTRL_TYPE" in
		int | int64 | bool | menu | bitmask)
			if set_ctrl "$dev" "$name" "$CTRL_DEFAULT"; then
				applied=$((applied + 1))
			else
				skipped=$((skipped + 1))
			fi
			;;
		esac
	done < <(ctrl_names "$dev")
	wt --msgbox "Reset $applied control(s) to default, skipped $skipped (read-only or rejected)." 8 60
}

# Profiles: flat "name=value" text, one v4l2-ctl control per line — the
# same tolerant-per-line-apply idiom start-canon-webcam.sh's -q quality
# preset uses, so a control a driver doesn't accept just gets skipped
# rather than aborting the whole profile.
action_save_profile() {
	local dev
	dev=$(pick_device "Choose a camera to snapshot") || return 0
	[ -z "$dev" ] && return 0

	local pname
	pname=$(wt --inputbox "Profile name (e.g. 'video-call', 'daylight'):" 8 60 3>&1 1>&2 2>&3) || return 0
	[ -z "$pname" ] && return 0

	mkdir -p "$PROFILE_DIR" || {
		wt --msgbox "Could not create $PROFILE_DIR." 8 60
		return 1
	}
	local file="$PROFILE_DIR/${pname}.conf"
	: >"$file"
	local name
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		parse_ctrl "$dev" "$name"
		case "$CTRL_TYPE" in
		int | int64 | bool | menu | bitmask) printf '%s=%s\n' "$name" "$CTRL_VALUE" >>"$file" ;;
		esac
	done < <(ctrl_names "$dev")
	wt --msgbox "Saved:\n$file" 8 60
}

action_load_profile() {
	local dev
	dev=$(pick_device "Choose a camera to apply a profile to") || return 0
	[ -z "$dev" ] && return 0

	if [ ! -d "$PROFILE_DIR" ] || [ -z "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]; then
		wt --msgbox "No saved profiles in $PROFILE_DIR yet." 8 60
		return 0
	fi

	local menu_args=() f base
	for f in "$PROFILE_DIR"/*.conf; do
		[ -e "$f" ] || continue
		base="${f##*/}"
		menu_args+=("$base" "")
	done
	local chosen
	chosen=$(wt --menu "Apply which profile to $dev?" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$chosen" ] && return 0

	local name val applied=0 skipped=0
	while IFS='=' read -r name val; do
		[ -z "$name" ] && continue
		case "$name" in '#'*) continue ;; esac
		if set_ctrl "$dev" "$name" "$val"; then
			applied=$((applied + 1))
		else
			skipped=$((skipped + 1))
		fi
	done <"$PROFILE_DIR/$chosen"
	wt --msgbox "Applied $applied setting(s), skipped $skipped (unsupported on this camera/mode)." 8 60
}

# ---------------------------------------------------------------------------
# TODO / scaffolded, not yet implemented:
#
# action_preview(): launch `ffplay <device>` (or `mpv av://v4l2:<device>`)
# in a terminal so a value change (esp. exposure/focus) can be judged
# visually instead of by number alone. Needs a decision on which terminal
# emulator to shell out to on this dwm setup rather than guessing one.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
	while true; do
		local choice
		choice=$(wt --menu "Webcam control (v4l2)" 0 0 0 \
			"1" "Camera info & current control values" \
			"2" "Exposure & focus quick setup" \
			"3" "Browse & edit all controls" \
			"4" "Reset all controls to defaults" \
			"5" "Save current settings as a profile" \
			"6" "Apply a saved profile" \
			"0" "Quit" \
			3>&1 1>&2 2>&3) || break

		case "$choice" in
		1) action_show_info ;;
		2) action_exposure_focus ;;
		3) action_browse_ctrls ;;
		4) action_reset_defaults ;;
		5) action_save_profile ;;
		6) action_load_profile ;;
		0 | "") break ;;
		esac
	done
}

main() {
	require_tools
	v4l2-ctl --list-devices >/dev/null 2>&1 || die "v4l2-ctl can't enumerate devices (no /dev/video* nodes, or v4l-utils not installed properly)"
	main_menu
}

main "$@"
