#!/usr/bin/env bash
# lib/tui.sh — helpers shared by audio-tui.sh, display-tui.sh and
# webcam-tui.sh (and sync-root-gtk-theme.sh's --pick), which source it from
# beside their own real path. Not meant to be run on its own. One copy, so a
# fix to the dialog handling, error reporting or number parsing reaches
# every TUI at once. The shebang is only there so the repo's lint
# (list-lint-files.sh finds shell files by shebang) picks this file up.

# The running TUI's name, for whiptail's backtitle.
readonly PROG="${0##*/}"

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

# require_tools TOOL... — exit, naming what's missing, unless every TOOL is
# on PATH.
require_tools() {
	local t missing=()
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	[ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# whiptail wrapper. This whiptail build (newt, no dialog compat layer) has
# no top-level --height/--width option — only --menu/--msgbox/etc. accept
# height/width, positionally, after the text. Every call site passes
# "0 0[ 0]" for those, which newt auto-sizes to fit the content; do not add
# --height/--width flags here, they're silently rejected ("--height:
# unknown option") and whiptail exits without drawing anything.
#
# Dialogs that only show something (msgbox, yesno, infobox, textbox) draw
# straight on /dev/tty. whiptail draws on stdout, so inside $(...), where
# every picker runs, one would be drawn into the caller's variable while
# whiptail waits for a key on a screen that looks frozen. Dialogs that
# return a choice (menu, inputbox, ...) are left alone: callers capture it
# by swapping stdout and stderr (3>&1 1>&2 2>&3). The scan stops at the
# first box option, skipping the values of options that take one.
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

# run_or_report WHAT CMD... — run CMD for its effect (stdout discarded). If
# it fails, show "WHAT:" and its stderr (or exit status) in a msgbox rather
# than let the error flash up only to be painted over by the next screen.
# Returns CMD's status. Call it directly, not in $(...), where its caller
# couldn't see a side effect such as display-tui's cache being marked stale.
run_or_report() {
	local what="$1" err status
	shift
	err=$("$@" 2>&1 >/dev/null)
	status=$?
	if [ "$status" -ne 0 ]; then
		wt --msgbox "$what:\n${err:-exit status $status}" 12 70
	fi
	return "$status"
}

# Prints $1 with any leading zeros dropped if it's a decimal integer ("08"
# -> "8", "-007" -> "-7", "-0" -> "0"), else unchanged (e.g. "0x10"). Typed
# and file-read numbers need this before use: bash arithmetic reads "08" as
# bad octal and aborts, and tools that parse with strtol(..., 0), such as
# v4l2-ctl, would set "0250" as 168. Prints only, no dialog.
normalize_int() {
	local v="$1"
	if [[ "$v" =~ ^(-?)0*([0-9]+)$ ]]; then
		v="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
		[ "$v" = "-0" ] && v=0
	fi
	printf '%s' "$v"
}

# int_le A B — whether integer A <= B, for decimal integers of any length
# in normalize_int's form (no leading zeros, no "-0"). Compared as strings,
# by sign, then digit count, then digit by digit in 9-digit chunks, because
# [ and $((...)) are 64-bit and misread anything past int64.
int_le() {
	local a="$1" b="$2" i x y
	case "$a:$b" in
	-*:-*)
		int_le "${b#-}" "${a#-}" # both negative: compare magnitudes, flipped
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
