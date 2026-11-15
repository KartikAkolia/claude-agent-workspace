#!/usr/bin/env bash
# Helpers shared by audio-tui.sh, display-tui.sh, webcam-tui.sh and
# sync-root-gtk-theme.sh --pick, which source this file. Not run on its own.
# Docs: docs/desktop-tuis.md

readonly PROG="${0##*/}"

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

require_tools() {
	local t missing=()
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	[ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# No --height/--width (this whiptail rejects them); display-only boxes go to /dev/tty, not into $(...).
wt() {
	local i
	for ((i = 1; i <= $#; i++)); do
		case "${!i}" in
		--msgbox | --yesno | --infobox | --textbox)
			whiptail --backtitle "$PROG" "$@" >/dev/tty
			return
			;;
		--menu | --inputbox | --passwordbox | --checklist | --radiolist | --gauge) break ;;
		--default-item | --title | --yes-button | --no-button | --ok-button | --cancel-button) i=$((i + 1)) ;;
		esac
	done
	whiptail --backtitle "$PROG" "$@"
}

pick_menu() {
	local title="$1" empty="$2" choice
	shift 2
	[ "$#" -gt 0 ] || {
		wt --msgbox "$empty" 8 50
		return 1
	}
	choice=$(wt --menu "$title" 0 0 0 "$@" 3>&1 1>&2 2>&3) || return
	[ -n "$choice" ] && printf '%s' "$choice"
}

run_or_report() {
	local what="$1" err status
	shift
	err=$("$@" 2>&1 >/dev/null)
	status=$?
	[ "$status" -eq 0 ] || wt --msgbox "$what:\n${err:-exit status $status}" 12 70
	return "$status"
}

normalize_int() {
	local v="$1"
	[[ "$v" =~ ^(-?)0*([0-9]+)$ ]] && v="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
	[ "$v" = "-0" ] && v=0
	printf '%s' "$v"
}

int_le() {
	local a="$1" b="$2" i x y
	case "$a:$b" in
	-*:-*)
		int_le "${b#-}" "${a#-}"
		return
		;;
	-*:*) return 0 ;;
	*:-*) return 1 ;;
	esac
	[ "${#a}" -eq "${#b}" ] || {
		[ "${#a}" -lt "${#b}" ]
		return
	}
	for ((i = 0; i < ${#a}; i += 9)); do
		x=$((10#${a:i:9})) y=$((10#${b:i:9}))
		[ "$x" -eq "$y" ] || {
			[ "$x" -lt "$y" ]
			return
		}
	done
	return 0
}
