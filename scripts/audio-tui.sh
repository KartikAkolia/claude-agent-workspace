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

# Volume step for "up"/"down", and the ceiling no change made here raises a
# volume past, "up" steps included — see action_volume(). VOL_NORM is
# PA_VOLUME_NORM, the raw pa_volume_t value pactl reports for 100%.
readonly VOL_STEP_PCT=5 VOL_CAP_PCT=150 VOL_NORM=65536

# Run a pactl change, surfacing a failure in a msgbox (lib/tui.sh's
# run_or_report).
run_pactl() { run_or_report "pactl $1 failed" pactl "$@"; }

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
#
# Callers always run these as x=$(pick_...), so stdout is the capture, not
# the terminal. Any msgbox here relies on wt drawing it on /dev/tty (see wt
# above); never call whiptail directly from one.
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
	# Monitor sources (a sink's "record what you hear" loopback) are
	# included, not filtered out — pavucontrol's own default view ("All
	# Input Devices") shows them too, and hiding them would make it
	# impossible to route a stream's recording to one. Tagged so they're
	# distinguishable from a physical mic/line input.
	while IFS=$'\t' read -r name desc; do
		[ -z "$name" ] && continue
		tag="$desc"
		case "$name" in *.monitor) tag="$tag [monitor]" ;; esac
		[ "$name" = "$default_mark" ] && tag="$tag (default)"
		menu_args+=("$name" "$tag")
	done < <(pa_json sources | jq -r '.[] | [.name, .description] | @tsv')

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
	run_pactl set-default-sink "$sink" && wt --msgbox "Default output set to:\n$sink" 8 60
}

action_default_source() {
	local source
	source=$(pick_source "Set default input device") || return 0
	[ -z "$source" ] && return 0
	run_pactl set-default-source "$source" && wt --msgbox "Default input set to:\n$source" 8 60
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
	run_pactl move-sink-input "$stream_id" "$sink" && wt --msgbox "Moved." 6 30
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
	run_pactl move-source-output "$stream_id" "$source" && wt --msgbox "Moved." 6 30
}

# "up" for action_volume: +VOL_STEP_PCT, but no channel ends above
# VOL_CAP_PCT. pactl's own relative "+5%" has no ceiling, so this reads the
# raw per-channel volumes and sets absolute ones instead: every channel
# rises by the same amount (an L/R balance survives), and the step shrinks
# so the loudest channel stops exactly at the cap.
volume_up_capped() {
	local kind="$1" name="$2" fields v max=0 step
	# inc is rounded, not truncated (3277 for 5%), so ten steps from 100%
	# land on the cap rather than 8 units short of it.
	local cap=$((VOL_CAP_PCT * VOL_NORM / 100)) inc=$(((VOL_STEP_PCT * VOL_NORM + 50) / 100))
	local cur=() new=()
	# First field: the channel count from channel_map, to check the values
	# line up with it (pactl's JSON keys volumes by channel position, so a
	# map with a repeated position would collapse two channels into one).
	fields=$(pa_json "${kind}s" | jq -r --arg n "$name" '.[] | select(.name==$n) |
		[(.channel_map // "" | split(",") | length), ((.volume // {})[] | .value)] | @tsv')
	read -r -a cur <<<"$fields"
	local nch="${cur[0]:-0}"
	cur=("${cur[@]:1}")
	for v in "${cur[@]}"; do
		if ! [[ "$v" =~ ^[0-9]+$ ]]; then
			cur=()
			break
		fi
		[ "$v" -gt "$max" ] && max="$v"
	done
	if [ "${#cur[@]}" -eq 0 ]; then
		wt --msgbox "Could not read the current volume of:\n$name" 8 60
		return 1
	fi

	step=$((cap - max))
	[ "$step" -gt "$inc" ] && step="$inc"
	if [ "$step" -le 0 ]; then
		wt --msgbox "Already at or above the ${VOL_CAP_PCT}% cap:\n$name" 8 60
		return 0
	fi
	if [ "${#cur[@]}" -eq "$nch" ]; then
		for v in "${cur[@]}"; do new+=("$((v + step))"); done
	else
		new=("$((max + step))") # can't match values to channels: move them together
	fi
	run_pactl "set-${kind}-volume" "$name" "${new[@]}"
}

# Volume/mute for one device, looped so +/- steps and mute-toggle can be
# applied repeatedly without re-picking the device each time. The menu
# reopens on the last action (--default-item), so a repeated Enter repeats
# it rather than jumping back to "up".
action_volume() {
	local kind="$1" # "sink" or "source"
	local name
	if [ "$kind" = sink ]; then
		name=$(pick_sink "Choose an output to adjust") || return 0
	else
		name=$(pick_source "Choose an input to adjust") || return 0
	fi
	[ -z "$name" ] && return 0

	local choice="up" vol vol_num mute status
	while true; do
		# One value per line: every channel's percentage (joined only when
		# they differ), the loudest channel as a plain number for the
		# inputbox default (pactl reports e.g. "90%", with the literal '%'),
		# and the mute state.
		vol="" vol_num="" mute=""
		{
			read -r vol
			read -r vol_num
			read -r mute
		} < <(pa_json "${kind}s" | jq -r --arg n "$name" '
			.[] | select(.name==$n) | [(.volume // {})[] | .value_percent] as $p |
			($p | if (unique | length) > 1 then join(" / ") else .[0] // "" end),
			($p | map(rtrimstr("%") | tonumber?) | max // ""), .mute')
		status="volume: ${vol:-?}  muted: ${mute:-?}"

		choice=$(wt --default-item "$choice" --menu "$name\n$status" 0 0 0 \
			"up" "Volume +${VOL_STEP_PCT}% (stops at ${VOL_CAP_PCT}%)" \
			"down" "Volume -${VOL_STEP_PCT}%" \
			"mute" "Toggle mute" \
			"set" "Set exact volume %" \
			"back" "Back to main menu" \
			3>&1 1>&2 2>&3) || return 0

		case "$choice" in
		up) volume_up_capped "$kind" "$name" ;;
		down) run_pactl "set-${kind}-volume" "$name" "-${VOL_STEP_PCT}%" ;;
		mute) run_pactl "set-${kind}-mute" "$name" toggle ;;
		set)
			local pct
			pct=$(wt --inputbox "Volume percent (0-${VOL_CAP_PCT}):" 8 40 "${vol_num:-100}" 3>&1 1>&2 2>&3) || continue
			pct="${pct%\%}" # tolerate a trailing '%' if the user kept/typed one
			case "$pct" in
			'' | *[!0-9]*)
				wt --msgbox "Not a number: $pct" 6 40
				continue
				;;
			esac
			pct=$(normalize_int "$pct") # "0150" is 150, not octal
			# The prompt says 0-150; actually enforce it. (pactl/PipeWire
			# themselves accept much higher — pavucontrol's own slider caps
			# at PA_VOLUME_UI_MAX, ~355% of normal — but 150% is a more
			# conservative ceiling for unattended speaker/hearing safety,
			# chosen deliberately rather than matching that. "up" honours
			# the same cap; see volume_up_capped.) int_le compares as
			# strings, so a number too big for 64 bits can't overflow it.
			if ! int_le "$pct" "$VOL_CAP_PCT"; then
				wt --msgbox "$pct% is above the ${VOL_CAP_PCT}% cap." 6 40
				continue
			fi
			run_pactl "set-${kind}-volume" "$name" "${pct}%"
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

	local menu_args=() active key desc avail
	active=$(pa_json cards | jq -r --arg c "$card" '.[] | select(.name==$c) | .active_profile')
	while IFS=$'\t' read -r key desc avail; do
		[ -z "$key" ] && continue
		# pactl reports a profile's .available (e.g. an HDMI profile before
		# any display is detected) — flag it rather than silently offering
		# a profile switch that won't actually do anything useful.
		[ "$avail" = "false" ] && desc="$desc [unavailable]"
		[ "$key" = "$active" ] && desc="$desc (active)"
		menu_args+=("$key" "$desc")
	done < <(pa_json cards | jq -r --arg c "$card" \
		'.[] | select(.name==$c) | .profiles | to_entries[] | [.key, .value.description, .value.available] | @tsv')

	local profile
	profile=$(wt --menu "Profile for $card" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$profile" ] && return 0
	run_pactl set-card-profile "$card" "$profile" && wt --msgbox "Profile set to:\n$profile" 8 60
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

	local active menu_args=() pname pdesc avail
	active=$(pa_json "${kind}s" | jq -r --arg n "$name" '.[] | select(.name==$n) | .active_port // empty')
	while IFS=$'\t' read -r pname pdesc avail; do
		[ -z "$pname" ] && continue
		# pactl reports "available"/"not available"/"availability unknown"
		# (jack-detection state) — surface it, since picking a port that's
		# reported not plugged in is a silent no-op otherwise. Leave the
		# common "unknown" case (most jacks can't detect this) unannotated.
		case "$avail" in
		"not available") pdesc="$pdesc [not plugged in]" ;;
		"available") pdesc="$pdesc [plugged in]" ;;
		esac
		[ "$pname" = "$active" ] && pdesc="$pdesc (active)"
		menu_args+=("$pname" "$pdesc")
	done < <(pa_json "${kind}s" | jq -r --arg n "$name" \
		'.[] | select(.name==$n) | .ports[]? | [.name, .description, .availability] | @tsv')

	if [ "${#menu_args[@]}" -eq 0 ]; then
		wt --msgbox "$name has no selectable ports." 8 50
		return 0
	fi

	local port
	port=$(wt --menu "Port for $name" 0 0 0 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$port" ] && return 0
	run_pactl "set-${kind}-port" "$name" "$port" && wt --msgbox "Port set." 6 30
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

# Reopens on the last item picked (--default-item), like action_volume.
main_menu() {
	local choice="1"
	while true; do
		choice=$(wt --default-item "$choice" --menu "Audio device manager" 0 0 0 \
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
	require_tools whiptail pactl jq
	pactl info >/dev/null 2>&1 || die "pactl can't reach the sound server (is PipeWire/PulseAudio running?)"
	main_menu
}

main "$@"
