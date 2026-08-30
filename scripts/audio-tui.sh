#!/usr/bin/env bash
# audio-tui.sh — whiptail front end for PipeWire/PulseAudio device and
# stream management, for cases pavucontrol's GUI is slower for on a
# keyboard-driven, mouse-optional setup (dwm): per-app stream routing,
# card profile switching (e.g. disabling an unused HDMI output outright),
# and active-port selection, all from one keyboard-driven menu tree.
#
# Backend: `pactl -f json ...` for introspection (stable, jq-friendly),
# `pactl <verb>` for changes. Works against PipeWire's pulse-compat layer
# exactly as pavucontrol does — no direct pw-cli/wpctl calls, so behavior
# stays consistent with what pavucontrol already shows.
#
# Deliberately not using `set -e`: whiptail's own exit code (1/255 on
# Cancel/Esc) is normal control flow here, checked explicitly at each
# menu, not something a blanket -e should abort the whole TUI over.
set -uo pipefail

readonly PROG="${0##*/}"

# ---------------------------------------------------------------------------
# Setup / preflight
# ---------------------------------------------------------------------------

require_tools() {
	local missing=() cmd
	for cmd in whiptail pactl jq; do
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
# "0 0[ 0]" for those, which newt auto-sizes to fit the content; do not
# add --height/--width flags here, they're silently rejected ("--height:
# unknown option") and whiptail exits without drawing anything.
wt() {
	whiptail --backtitle "$PROG" "$@"
}

# ---------------------------------------------------------------------------
# Data helpers — thin wrappers over `pactl -f json`, one jq filter each so
# the menu-building functions stay readable.
# ---------------------------------------------------------------------------

pa_json() {
	# $1: pactl noun, e.g. "sinks", "sources", "cards", "sink-inputs"
	pactl -f json list "$1" 2>/dev/null
}

default_sink_name() { pactl get-default-sink 2>/dev/null; }
default_source_name() { pactl get-default-source 2>/dev/null; }

# ---------------------------------------------------------------------------
# Pickers — build a whiptail --menu from pactl JSON, return the chosen
# object's `name` field on stdout. Empty stdout + nonzero exit = cancelled.
# ---------------------------------------------------------------------------

pick_sink() {
	local title="$1" default_mark
	default_mark=$(default_sink_name)
	local menu_args=()
	local name desc tag
	while IFS=$'\t' read -r name desc; do
		[ -z "$name" ] && continue
		tag="$desc"
		[ "$name" = "$default_mark" ] && tag="$tag (default)"
		menu_args+=("$name" "$tag")
	done < <(pa_json sinks | jq -r '.[] | [.name, .description] | @tsv')

	[ "${#menu_args[@]}" -eq 0 ] && {
		wt --msgbox "No output devices found." 8 50
		return 1
	}
	wt --menu "$title" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

pick_source() {
	local title="$1" default_mark
	default_mark=$(default_source_name)
	local menu_args=()
	local name desc tag
	while IFS=$'\t' read -r name desc; do
		[ -z "$name" ] && continue
		tag="$desc"
		[ "$name" = "$default_mark" ] && tag="$tag (default)"
		menu_args+=("$name" "$tag")
	done < <(pa_json sources | jq -r '.[] | select(.name | endswith(".monitor") | not) | [.name, .description] | @tsv')

	[ "${#menu_args[@]}" -eq 0 ] && {
		wt --msgbox "No input devices found." 8 50
		return 1
	}
	wt --menu "$title" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

pick_card() {
	local menu_args=()
	local name desc
	while IFS=$'\t' read -r name desc; do
		[ -z "$name" ] && continue
		menu_args+=("$name" "$desc")
	done < <(pa_json cards | jq -r '.[] | [.name, (.properties["device.description"] // .name)] | @tsv')

	[ "${#menu_args[@]}" -eq 0 ] && {
		wt --msgbox "No sound cards found." 8 50
		return 1
	}
	wt --menu "Choose a sound card" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_default_sink() {
	local sink
	sink=$(pick_sink "Set default output device") || return 0
	[ -z "$sink" ] && return 0
	pactl set-default-sink "$sink" && wt --msgbox "Default output set to:\n$sink" 8 60
}

action_default_source() {
	local source
	source=$(pick_source "Set default input device") || return 0
	[ -z "$source" ] && return 0
	pactl set-default-source "$source" && wt --msgbox "Default input set to:\n$source" 8 60
}

# Per-app playback routing: pavucontrol's "Playback" tab, but keyboard-only
# and scriptable (a future step could pre-route a specific app on launch).
action_route_playback() {
	local menu_args=() id appname
	while IFS=$'\t' read -r id appname; do
		[ -z "$id" ] && continue
		menu_args+=("$id" "$appname")
	done < <(pa_json sink-inputs | jq -r '.[] | [.index, (.properties["application.name"] // "unknown")] | @tsv')

	if [ "${#menu_args[@]}" -eq 0 ]; then
		wt --msgbox "No active playback streams." 8 50
		return 0
	fi

	local stream_id
	stream_id=$(wt --menu "Choose a playback stream to move" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$stream_id" ] && return 0

	local sink
	sink=$(pick_sink "Move stream $stream_id to which output?") || return 0
	[ -z "$sink" ] && return 0
	pactl move-sink-input "$stream_id" "$sink" && wt --msgbox "Moved." 6 30
}

# Per-app recording routing: pavucontrol's "Recording" tab equivalent.
action_route_recording() {
	local menu_args=() id appname
	while IFS=$'\t' read -r id appname; do
		[ -z "$id" ] && continue
		menu_args+=("$id" "$appname")
	done < <(pa_json source-outputs | jq -r '.[] | [.index, (.properties["application.name"] // "unknown")] | @tsv')

	if [ "${#menu_args[@]}" -eq 0 ]; then
		wt --msgbox "No active recording streams." 8 50
		return 0
	fi

	local stream_id
	stream_id=$(wt --menu "Choose a recording stream to move" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$stream_id" ] && return 0

	local source
	source=$(pick_source "Move stream $stream_id to which input?") || return 0
	[ -z "$source" ] && return 0
	pactl move-source-output "$stream_id" "$source" && wt --msgbox "Moved." 6 30
}

# Volume/mute for one device, looped so +/- steps and mute-toggle can be
# applied repeatedly without re-picking the device each time.
action_volume() {
	local kind="$1" # "sink" or "source"
	local name
	if [ "$kind" = sink ]; then
		name=$(pick_sink "Choose an output to adjust") || return 0
	else
		name=$(pick_source "Choose an input to adjust") || return 0
	fi
	[ -z "$name" ] && return 0

	while true; do
		local vol vol_num mute status choice
		vol=$(pa_json "${kind}s" | jq -r --arg n "$name" \
			'.[] | select(.name==$n) | .volume | to_entries[0].value.value_percent')
		# pactl's JSON reports this as e.g. "90%" (with the literal '%'); strip
		# it for use as a plain-number inputbox default.
		vol_num="${vol%\%}"
		mute=$(pa_json "${kind}s" | jq -r --arg n "$name" \
			'.[] | select(.name==$n) | .mute')
		status="volume: ${vol:-?}  muted: ${mute:-?}"

		choice=$(wt --menu "$name\n$status" 0 0 0 \
			"up" "Volume +5%" \
			"down" "Volume -5%" \
			"mute" "Toggle mute" \
			"set" "Set exact volume %" \
			"back" "Back to main menu" \
			3>&1 1>&2 2>&3) || return 0

		case "$choice" in
		up) pactl "set-${kind}-volume" "$name" +5% ;;
		down) pactl "set-${kind}-volume" "$name" -5% ;;
		mute) pactl "set-${kind}-mute" "$name" toggle ;;
		set)
			local pct
			pct=$(wt --inputbox "Volume percent (0-150):" 8 40 "${vol_num:-100}" 3>&1 1>&2 2>&3) || continue
			pct="${pct%\%}" # tolerate a trailing '%' if the user kept/typed one
			case "$pct" in
			'' | *[!0-9]*)
				wt --msgbox "Not a number: $pct" 6 40
				continue
				;;
			esac
			pactl "set-${kind}-volume" "$name" "${pct}%"
			;;
		back | "") return 0 ;;
		esac
	done
}

# Card profile switch — this is the sharpest tool here: setting a card's
# profile to "off" is a clean, reversible way to disable an output you
# never use (e.g. a laptop's HDMI-out when no monitor is attached), no
# kernel module blacklisting required.
action_card_profile() {
	local card
	card=$(pick_card) || return 0
	[ -z "$card" ] && return 0

	local menu_args=() active key desc
	active=$(pa_json cards | jq -r --arg c "$card" '.[] | select(.name==$c) | .active_profile')
	while IFS=$'\t' read -r key desc; do
		[ -z "$key" ] && continue
		[ "$key" = "$active" ] && desc="$desc (active)"
		menu_args+=("$key" "$desc")
	done < <(pa_json cards | jq -r --arg c "$card" \
		'.[] | select(.name==$c) | .profiles | to_entries[] | [.key, .value.description] | @tsv')

	local profile
	profile=$(wt --menu "Profile for $card" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$profile" ] && return 0
	pactl set-card-profile "$card" "$profile" && wt --msgbox "Profile set to:\n$profile" 8 60
}

# Active port on one device — the same jack-vs-speaker or line-vs-mic
# switch pavucontrol exposes under a device's dropdown, surfaced directly.
action_port() {
	local kind="$1" name
	if [ "$kind" = sink ]; then
		name=$(pick_sink "Choose an output") || return 0
	else
		name=$(pick_source "Choose an input") || return 0
	fi
	[ -z "$name" ] && return 0

	local active menu_args=() pname pdesc
	active=$(pa_json "${kind}s" | jq -r --arg n "$name" '.[] | select(.name==$n) | .active_port // empty')
	while IFS=$'\t' read -r pname pdesc; do
		[ -z "$pname" ] && continue
		[ "$pname" = "$active" ] && pdesc="$pdesc (active)"
		menu_args+=("$pname" "$pdesc")
	done < <(pa_json "${kind}s" | jq -r --arg n "$name" \
		'.[] | select(.name==$n) | .ports[]? | [.name, .description] | @tsv')

	if [ "${#menu_args[@]}" -eq 0 ]; then
		wt --msgbox "$name has no selectable ports." 8 50
		return 0
	fi

	local port
	port=$(wt --menu "Port for $name" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$port" ] && return 0
	pactl "set-${kind}-port" "$name" "$port" && wt --msgbox "Port set." 6 30
}

# ---------------------------------------------------------------------------
# TODO / scaffolded, not yet implemented — noted for a follow-up pass:
#
# action_presets(): save the current default sink/source + card profiles
# to a named file under ~/.config/audio-tui/presets/<name>.conf, and a
# separate "apply preset" action that reads one back and replays it via
# the same pactl calls above. Needs a decision on file format (flat
# KEY=value vs one pactl-command-per-line) before it's worth building —
# flagging as the natural next feature rather than guessing the format.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
	while true; do
		local choice
		choice=$(wt --menu "Audio device manager" 0 0 0 \
			"1" "Default output device" \
			"2" "Default input device" \
			"3" "Move a playback stream (per-app)" \
			"4" "Move a recording stream (per-app)" \
			"5" "Output volume / mute" \
			"6" "Input volume / mute" \
			"7" "Card profile (enable/disable outputs)" \
			"8" "Output port" \
			"9" "Input port" \
			"0" "Quit" \
			3>&1 1>&2 2>&3) || break

		case "$choice" in
		1) action_default_sink ;;
		2) action_default_source ;;
		3) action_route_playback ;;
		4) action_route_recording ;;
		5) action_volume sink ;;
		6) action_volume source ;;
		7) action_card_profile ;;
		8) action_port sink ;;
		9) action_port source ;;
		0 | "") break ;;
		esac
	done
}

main() {
	require_tools
	pactl info >/dev/null 2>&1 || die "pactl can't reach the sound server (is PipeWire/PulseAudio running?)"
	main_menu
}

main "$@"
