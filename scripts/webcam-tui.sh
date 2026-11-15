#!/usr/bin/env bash
# webcam-tui.sh — whiptail front end for v4l2-ctl camera controls: exposure and
# focus presets, browsing and editing every control, defaults and profiles.
# No set -e: whiptail's Cancel/Esc status is normal control flow here.
# Docs: docs/desktop-tuis.md
set -uo pipefail

tui_lib="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/tui.sh"
if [ ! -r "$tui_lib" ]; then
	printf 'error: %s is missing; run %s from the repo checkout, or keep scripts/lib/ beside it\n' "$tui_lib" "${0##*/}" >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$tui_lib"

readonly PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/webcam-tui/profiles"
readonly SETTLE_SECS=2 SETTLE_TRIES=3

is_capture_node() {
	v4l2-ctl -d "$1" -D 2>/dev/null | awk '
		/^[[:space:]]*Device Caps/ { found=1; next }
		found && /^[^[:space:]]/ { found=0 }
		found && /Video Capture/ { print; exit }
	' | grep -q .
}

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
	local menu_args=() node name
	while IFS=$'\t' read -r node name; do
		[ -z "$node" ] && continue
		menu_args+=("$node" "$name ($node)")
	done < <(list_capture_devices)
	[ "${#menu_args[@]}" -gt 0 ] || {
		wt --msgbox "No capture-capable video devices found." 8 60
		return 1
	}
	pick_menu "$1" "" "${menu_args[@]}"
}

list_ctrls_raw() { v4l2-ctl -d "$1" --list-ctrls-menus 2>/dev/null; }

ctrl_names() { list_ctrls_raw "$1" | awk '$2 ~ /^0x[0-9a-fA-F]+$/ { print $1 }'; }

ctrl_line() { list_ctrls_raw "$1" | awk -v n="$2" '$1==n && $2 ~ /^0x[0-9a-fA-F]+$/'; }

ctrl_menu_items() {
	list_ctrls_raw "$1" | awk -v n="$2" '
		$1==n && $2 ~ /^0x[0-9a-fA-F]+$/ { grab=1; next }
		grab && $0 ~ /^[[:space:]]+[0-9]+:/ { print; next }
		grab { grab=0 }
	'
}

parse_ctrl() {
	local line
	line=$(ctrl_line "$1" "$2")
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

set_ctrl() { v4l2-ctl -d "$1" --set-ctrl="$2=$3" >/dev/null 2>&1; }

run_v4l2_set() { run_or_report "v4l2-ctl failed setting $2=$3" v4l2-ctl -d "$1" --set-ctrl="$2=$3"; }

ctrl_cur() { v4l2-ctl -d "$1" -C "$2" 2>/dev/null | awk -F': ' '{ split($2, v, " "); print v[1]; exit }'; }

set_ctrl_settled() {
	local dev="$1" name="$2" val="$3" try cur
	run_v4l2_set "$dev" "$name" "$val" || return 1
	parse_ctrl "$dev" "$name" && [ "$CTRL_INACTIVE" -eq 1 ] && return 3
	for ((try = 1; try <= SETTLE_TRIES; try++)); do
		sleep "$SETTLE_SECS"
		cur=$(ctrl_cur "$dev" "$name")
		[ "$cur" = "$val" ] && return 0
		[ "$try" -lt "$SETTLE_TRIES" ] && set_ctrl "$dev" "$name" "$val"
	done
	wt --msgbox "$name was set to $val but the camera keeps moving it (now ${cur:-unreadable}).\nTry again in a few seconds, or pick a different value." 10 70
	return 2
}

check_int_value() {
	local -n civ_ref="$2"
	civ_ref=$(normalize_int "$civ_ref")
	local civ_name="$1" civ_val="$civ_ref" civ_step="${CTRL_STEP:-1}" civ_err=""
	if ! [[ "$civ_val" =~ ^-?[0-9]+$ ]]; then
		civ_err="Not a number: $civ_val"
	elif ! int_le "$CTRL_MIN" "$civ_val" || ! int_le "$civ_val" "$CTRL_MAX"; then
		civ_err="$civ_val is outside $civ_name's range ($CTRL_MIN-$CTRL_MAX)."
	elif [ "$civ_step" -gt 1 ] && [ $(((civ_val % civ_step - CTRL_MIN % civ_step) % civ_step)) -ne 0 ]; then
		civ_err="$civ_val isn't a valid $civ_name value: it must be $CTRL_MIN plus a multiple of $civ_step."
	fi
	[ -z "$civ_err" ] && return 0
	wt --msgbox "$civ_err" 8 60
	return 1
}

profile_entries() {
	local name val
	while IFS='=' read -r name val; do
		[ -z "$name" ] && continue
		case "$name" in '#'*) continue ;; esac
		printf '%s=%s\n' "$name" "$(normalize_int "$val")"
	done <"$1"
}

edit_ctrl() {
	local dev="$1" name="$2" setter="${3:-run_v4l2_set}" hint="" new items=() line idx label choice val
	parse_ctrl "$dev" "$name" || {
		wt --msgbox "Could not read $name on $dev." 8 50
		return 1
	}
	[ "$CTRL_INACTIVE" -eq 1 ] && hint=" (currently inactive/read-only on this driver — change may be a no-op)"

	case "$CTRL_TYPE" in
	bool)
		new=$([ "$CTRL_VALUE" = 1 ] && echo 0 || echo 1)
		wt --yesno "$name is currently $CTRL_VALUE.$hint\n\nToggle to $new?" 10 60 || return 1
		run_v4l2_set "$dev" "$name" "$new"
		;;
	menu)
		while IFS= read -r line; do
			[[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*)$ ]] || continue
			idx="${BASH_REMATCH[1]}"
			label="${BASH_REMATCH[2]}"
			[ "$idx" = "$CTRL_VALUE" ] && label="$label (current)"
			items+=("$idx" "$label")
		done < <(ctrl_menu_items "$dev" "$name")
		choice=$(pick_menu "$name$hint" "No menu items reported for $name." "${items[@]}") || return 1
		run_v4l2_set "$dev" "$name" "$choice"
		;;
	int | int64)
		val=$(wt --inputbox "$name (min=$CTRL_MIN max=$CTRL_MAX step=${CTRL_STEP:-1}, default=$CTRL_DEFAULT).$hint" 10 70 "$CTRL_VALUE" 3>&1 1>&2 2>&3) || return 1
		check_int_value "$name" val || return 1
		"$setter" "$dev" "$name" "$val"
		;;
	*)
		wt --msgbox "$name is a $CTRL_TYPE control — not editable from this menu yet.\nUse: v4l2-ctl -d $dev --set-ctrl=$name=<value>" 10 70
		return 1
		;;
	esac
}

action_show_info() {
	local dev tmp
	dev=$(pick_device "Choose a camera") || return 0
	tmp=$(mktemp) || die "mktemp failed"
	{
		v4l2-ctl -d "$dev" -D
		printf '\n'
		v4l2-ctl -d "$dev" --list-ctrls-menus
	} >"$tmp" 2>&1
	wt --textbox "$tmp" 0 0
	rm -f "$tmp"
}

action_browse_ctrls() {
	local dev choice="" items name status
	dev=$(pick_device "Choose a camera to browse controls") || return 0
	while true; do
		items=()
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

		choice=$(wt --default-item "${choice:-${items[0]}}" --menu "Controls on $dev" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3) || return 0
		[ -z "$choice" ] && return 0
		edit_ctrl "$dev" "$choice"
	done
}

action_exposure_focus() {
	local dev exp_auto exp_abs foc_auto foc_abs choice="stable" status ctrl
	dev=$(pick_device "Choose a camera to configure exposure & focus for") || return 0
	exp_auto=$(resolve_ctrl_name "$dev" exposure_auto auto_exposure) || exp_auto=""
	exp_abs=$(resolve_ctrl_name "$dev" exposure_absolute exposure_time_absolute) || exp_abs=""
	foc_auto=$(resolve_ctrl_name "$dev" focus_auto focus_automatic_continuous) || foc_auto=""
	foc_abs=$(resolve_ctrl_name "$dev" focus_absolute) || foc_abs=""

	if [ -z "$exp_auto$exp_abs$foc_auto$foc_abs" ]; then
		wt --msgbox "$dev doesn't report any exposure/focus controls under the usual names.\nUse 'Browse & edit all controls' instead." 10 70
		return 0
	fi

	while true; do
		status=""
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

		choice=$(wt --default-item "$choice" --menu "$dev$status" 0 0 0 \
			"stable" "Manual preset: lock exposure + focus (video calls/streaming)" \
			"auto" "Auto preset: revert to the camera's own auto-hunting" \
			"exposure" "Set exposure value only" \
			"focus" "Set focus value only" \
			"back" "Back to main menu" \
			3>&1 1>&2 2>&3) || return 0

		case "$choice" in
		stable) action_apply_manual_preset "$dev" "$exp_auto" "$exp_abs" "$foc_auto" "$foc_abs" ;;
		auto) action_apply_auto_preset "$dev" "$exp_auto" "$foc_auto" ;;
		exposure | focus)
			ctrl=$exp_abs
			[ "$choice" = exposure ] || ctrl=$foc_abs
			[ -n "$ctrl" ] || {
				wt --msgbox "No $choice-value control found on $dev." 6 60
				continue
			}
			edit_ctrl "$dev" "$ctrl" set_ctrl_settled
			;;
		back | "") return 0 ;;
		esac
	done
}

PRESET_NOTES=""

preset_set() {
	run_v4l2_set "$1" "$2" "$3" || PRESET_NOTES+="\n- $2: could not be set to $3"
}

preset_mode() {
	local idx
	[ -n "$2" ] || return 0
	idx=$(ctrl_menu_items "$1" "$2" | grep -iE "$3" | head -1 | sed -E 's/^[[:space:]]*([0-9]+):.*/\1/')
	if [ -n "$idx" ]; then
		preset_set "$1" "$2" "$idx"
	else
		PRESET_NOTES+="\n- $2: no $4 mode in its menu, left unchanged"
	fi
}

preset_value() {
	local dev="$1" name="$2" what="$3" extra="$4" val
	if ! parse_ctrl "$dev" "$name"; then
		PRESET_NOTES+="\n- $name: could not be read, left unchanged"
		return
	fi
	val=$(wt --inputbox "Fixed $what value (min=$CTRL_MIN max=$CTRL_MAX step=${CTRL_STEP:-1}$extra):" 8 60 "$CTRL_VALUE" 3>&1 1>&2 2>&3) || val=""
	if [ -z "$val" ]; then
		PRESET_NOTES+="\n- $name: no value entered, left unchanged"
		return
	fi
	if ! check_int_value "$name" val; then
		PRESET_NOTES+="\n- $name: $val rejected, left unchanged"
		return
	fi
	set_ctrl_settled "$dev" "$name" "$val"
	case $? in
	0) ;;
	2) PRESET_NOTES+="\n- $name: set to $val, but the camera keeps moving it" ;;
	3) PRESET_NOTES+="\n- $name: set to $val, but still inactive (its auto mode is on), so the camera may ignore it" ;;
	*) PRESET_NOTES+="\n- $name: could not be set to $val" ;;
	esac
}

preset_summary() {
	if [ -z "$PRESET_NOTES" ]; then
		wt --msgbox "$1 preset applied." 6 40
	else
		wt --msgbox "$1 preset not fully applied:$PRESET_NOTES" 16 76
	fi
}

action_apply_manual_preset() {
	local dev="$1" exp_auto="$2" exp_abs="$3" foc_auto="$4" foc_abs="$5"
	PRESET_NOTES=""
	preset_mode "$dev" "$exp_auto" manual manual
	[ -n "$exp_abs" ] && preset_value "$dev" "$exp_abs" exposure ""
	[ -n "$foc_auto" ] && preset_set "$dev" "$foc_auto" 0
	[ -n "$foc_abs" ] && preset_value "$dev" "$foc_abs" focus ", 0=infinity"
	preset_summary Manual
}

action_apply_auto_preset() {
	local dev="$1" exp_auto="$2" foc_auto="$3"
	PRESET_NOTES=""
	preset_mode "$dev" "$exp_auto" 'aperture|auto' auto
	[ -n "$foc_auto" ] && preset_set "$dev" "$foc_auto" 1
	preset_summary Auto
}

action_reset_defaults() {
	local dev name applied=0 skipped=0
	dev=$(pick_device "Choose a camera to reset to defaults") || return 0
	wt --yesno "Reset every writable control on $dev to its driver default?" 8 60 || return 0
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		parse_ctrl "$dev" "$name"
		[[ "$CTRL_TYPE" =~ ^(int|int64|bool|menu|bitmask)$ ]] || continue
		set_ctrl "$dev" "$name" "$CTRL_DEFAULT" && applied=$((applied + 1)) || skipped=$((skipped + 1))
	done < <(ctrl_names "$dev")
	wt --msgbox "Reset $applied control(s) to default, skipped $skipped (read-only or rejected)." 8 60
}

action_save_profile() {
	local dev pname err file tmp name count=0 write_ok=1
	dev=$(pick_device "Choose a camera to snapshot") || return 0
	pname=$(wt --inputbox "Profile name (e.g. 'video-call', 'daylight'):" 8 60 3>&1 1>&2 2>&3) || return 0
	case "$pname" in
	'' | */* | .* | -*)
		wt --msgbox "Not a usable profile name: '$pname'\nIt can't be empty, contain '/', or start with '.' or '-'." 9 70
		return 1
		;;
	esac

	if ! err=$(mkdir -p "$PROFILE_DIR" 2>&1); then
		wt --msgbox "Could not create $PROFILE_DIR:\n$err" 10 70
		return 1
	fi
	file="$PROFILE_DIR/${pname}.conf"
	if [ -e "$file" ] && [ ! -f "$file" ]; then
		wt --msgbox "$file exists and isn't a regular file; pick another name." 8 70
		return 1
	fi
	[ ! -e "$file" ] || wt --defaultno --yesno "Profile '$pname' already exists. Overwrite it?" 8 60 || return 0

	# Written beside the profile and renamed in only when complete, so a failed write never truncates it.
	if ! tmp=$(mktemp "$PROFILE_DIR/.save.XXXXXX" 2>&1); then
		wt --msgbox "Could not create a temporary file in $PROFILE_DIR:\n$tmp" 10 70
		return 1
	fi
	{
		while IFS= read -r name; do
			[ -z "$name" ] && continue
			parse_ctrl "$dev" "$name" || continue
			[[ "$CTRL_TYPE" =~ ^(int|int64|bool|menu|bitmask)$ ]] || continue
			printf '%s=%s\n' "$name" "$CTRL_VALUE" || write_ok=0
			count=$((count + 1))
		done < <(ctrl_names "$dev")
	} 2>/dev/null >"$tmp" || write_ok=0
	if [ "$write_ok" -eq 0 ]; then
		rm -f "$tmp"
		wt --msgbox "Could not write the profile (disk full or read-only?).\nNothing saved; $file is unchanged." 9 70
		return 1
	fi
	if [ "$count" -eq 0 ]; then
		rm -f "$tmp"
		wt --msgbox "$dev reported no controls that can be saved. Nothing saved." 8 70
		return 1
	fi
	chmod "$(printf '%o' "$((0666 & ~$(umask)))")" "$tmp" 2>/dev/null
	if ! err=$(mv -f "$tmp" "$file" 2>&1); then
		rm -f "$tmp"
		wt --msgbox "Could not save $file:\n$err" 10 70
		return 1
	fi
	wt --msgbox "Saved $count control(s) to:\n$file" 8 70
}

action_load_profile() {
	local dev menu_args=() f chosen pass name val kind applied=0 skipped=0 drifted=0
	dev=$(pick_device "Choose a camera to apply a profile to") || return 0
	for f in "$PROFILE_DIR"/*.conf; do
		[ -e "$f" ] || continue
		menu_args+=("${f##*/}" "")
	done
	if [ "${#menu_args[@]}" -eq 0 ]; then
		wt --msgbox "No saved profiles in $PROFILE_DIR yet." 8 60
		return 0
	fi
	chosen=$(pick_menu "Apply which profile to $dev?" "" "${menu_args[@]}") || return 0

	# Auto-mode switches first: a manual value set while its auto mode is on is ignored.
	for pass in auto manual; do
		while IFS='=' read -r name val; do
			[[ "$name" == *auto* ]] && kind=auto || kind=manual
			[ "$kind" = "$pass" ] || continue
			set_ctrl "$dev" "$name" "$val" && applied=$((applied + 1)) || skipped=$((skipped + 1))
		done < <(profile_entries "$PROFILE_DIR/$chosen")
	done
	sleep "$SETTLE_SECS"
	while IFS='=' read -r name val; do
		case "$name" in *auto*) continue ;; *exposure* | *focus*) ;; *) continue ;; esac
		parse_ctrl "$dev" "$name" && [ "$CTRL_INACTIVE" -eq 0 ] || continue
		[ "$CTRL_VALUE" = "$val" ] && continue
		set_ctrl "$dev" "$name" "$val"
		drifted=$((drifted + 1))
	done < <(profile_entries "$PROFILE_DIR/$chosen")
	wt --msgbox "Applied $applied setting(s), skipped $skipped (unsupported on this camera/mode), re-applied $drifted that drifted." 8 70
}

main_menu() {
	local choice="1"
	while true; do
		choice=$(wt --default-item "$choice" --menu "Webcam control (v4l2)" 0 0 0 \
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
	require_tools whiptail v4l2-ctl awk grep
	v4l2-ctl --list-devices >/dev/null 2>&1 || die "v4l2-ctl can't enumerate devices (no /dev/video* nodes, or v4l-utils not installed properly)"
	main_menu
}

main "$@"
