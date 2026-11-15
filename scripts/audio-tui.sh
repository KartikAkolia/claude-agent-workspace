#!/usr/bin/env bash
# audio-tui.sh — whiptail front end for PipeWire/PulseAudio via pactl: default
# devices, per-app stream routing, volume/mute, card profiles and ports.
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

readonly VOL_STEP_PCT=5 VOL_CAP_PCT=150 VOL_NORM=65536
declare -rA WHAT=([sink]=output [source]=input)

run_pactl() { run_or_report "pactl $1 failed" pactl "$@"; }

pa_json() { pactl -f json list "$1" 2>/dev/null; }

pick_dev() {
	local kind="$1" title="$2" default_mark items=() name desc tag
	default_mark=$(pactl "get-default-$kind" 2>/dev/null)
	while IFS=$'\t' read -r name desc; do
		[ -z "$name" ] && continue
		tag="$desc"
		case "$kind:$name" in source:*.monitor) tag="$tag [monitor]" ;; esac
		[ "$name" = "$default_mark" ] && tag="$tag (default)"
		items+=("$name" "$tag")
	done < <(pa_json "${kind}s" | jq -r '.[] | [.name, .description] | @tsv')
	pick_menu "$title" "No ${WHAT[$kind]} devices found." "${items[@]}"
}

action_default() {
	local kind="$1" what="${WHAT[$1]}" dev
	dev=$(pick_dev "$kind" "Set default $what device") || return 0
	run_pactl "set-default-$kind" "$dev" && wt --msgbox "Default $what set to:\n$dev" 8 60
}

action_route() {
	local kind="$1" stream=playback noun=sink-input items=() id appname stream_id dev
	[ "$kind" = source ] && stream=recording noun=source-output
	while IFS=$'\t' read -r id appname; do
		[ -z "$id" ] && continue
		items+=("$id" "$appname")
	done < <(pa_json "${noun}s" | jq -r '.[] | [.index, (.properties["application.name"] // "unknown")] | @tsv')
	stream_id=$(pick_menu "Choose a $stream stream to move" "No active $stream streams." "${items[@]}") || return 0
	dev=$(pick_dev "$kind" "Move stream $stream_id to which ${WHAT[$kind]}?") || return 0
	run_pactl "move-$noun" "$stream_id" "$dev" && wt --msgbox "Moved." 6 30
}

# Hearing safety: no change made here may raise a channel past VOL_CAP_PCT; pactl's +N% has no cap.
volume_up_capped() {
	local kind="$1" name="$2" fields v max=0 step cur=() new=()
	local cap=$((VOL_CAP_PCT * VOL_NORM / 100)) inc=$(((VOL_STEP_PCT * VOL_NORM + 50) / 100))
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
		new=("$((max + step))")
	fi
	run_pactl "set-${kind}-volume" "$name" "${new[@]}"
}

action_volume() {
	local kind="$1" name choice="up" vol vol_num mute status pct
	name=$(pick_dev "$kind" "Choose an ${WHAT[$kind]} to adjust") || return 0
	while true; do
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
			pct=$(wt --inputbox "Volume percent (0-${VOL_CAP_PCT}):" 8 40 "${vol_num:-100}" 3>&1 1>&2 2>&3) || continue
			pct="${pct%\%}"
			[[ -n "$pct" && "$pct" != *[!0-9]* ]] || {
				wt --msgbox "Not a number: $pct" 6 40
				continue
			}
			pct=$(normalize_int "$pct")
			int_le "$pct" "$VOL_CAP_PCT" || {
				wt --msgbox "$pct% is above the ${VOL_CAP_PCT}% cap." 6 40
				continue
			}
			run_pactl "set-${kind}-volume" "$name" "${pct}%"
			;;
		back | "") return 0 ;;
		esac
	done
}

action_card_profile() {
	local items=() card active key desc avail profile
	while IFS=$'\t' read -r key desc; do
		[ -z "$key" ] && continue
		items+=("$key" "$desc")
	done < <(pa_json cards | jq -r '.[] | [.name, (.properties["device.description"] // .name)] | @tsv')
	card=$(pick_menu "Choose a sound card" "No sound cards found." "${items[@]}") || return 0

	items=()
	active=$(pa_json cards | jq -r --arg c "$card" '.[] | select(.name==$c) | .active_profile')
	while IFS=$'\t' read -r key desc avail; do
		[ -z "$key" ] && continue
		[ "$avail" = "false" ] && desc="$desc [unavailable]"
		[ "$key" = "$active" ] && desc="$desc (active)"
		items+=("$key" "$desc")
	done < <(pa_json cards | jq -r --arg c "$card" \
		'.[] | select(.name==$c) | .profiles | to_entries[] | [.key, .value.description, .value.available] | @tsv')

	profile=$(wt --menu "Profile for $card" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3) || return 0
	[ -z "$profile" ] && return 0
	run_pactl set-card-profile "$card" "$profile" && wt --msgbox "Profile set to:\n$profile" 8 60
}

action_port() {
	local kind="$1" name active items=() pname pdesc avail port
	name=$(pick_dev "$kind" "Choose an ${WHAT[$kind]}") || return 0
	active=$(pa_json "${kind}s" | jq -r --arg n "$name" '.[] | select(.name==$n) | .active_port // empty')
	while IFS=$'\t' read -r pname pdesc avail; do
		[ -z "$pname" ] && continue
		case "$avail" in
		"not available") pdesc="$pdesc [not plugged in]" ;;
		"available") pdesc="$pdesc [plugged in]" ;;
		esac
		[ "$pname" = "$active" ] && pdesc="$pdesc (active)"
		items+=("$pname" "$pdesc")
	done < <(pa_json "${kind}s" | jq -r --arg n "$name" \
		'.[] | select(.name==$n) | .ports[]? | [.name, .description, .availability] | @tsv')
	port=$(pick_menu "Port for $name" "$name has no selectable ports." "${items[@]}") || return 0
	run_pactl "set-${kind}-port" "$name" "$port" && wt --msgbox "Port set." 6 30
}

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
		1) action_default sink ;;
		2) action_default source ;;
		3) action_route sink ;;
		4) action_route source ;;
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
