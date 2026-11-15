#!/usr/bin/env bash
# start-canon-webcam.sh — bridge a Canon EOS DSLR's USB live view onto a
# v4l2loopback webcam (gphoto2 -> ffmpeg -> /dev/videoN), optionally recording it.
#
# Usage: start-canon-webcam.sh [-n VIDEO_NR] [-d /dev/videoN] [-l "Card Label"] [-q] [-r FILE]
#   -n VIDEO_NR  v4l2loopback device number to create/use (default: 9)
#   -d DEVICE    /dev/videoN path; overrides -n, and its N is the number loaded
#   -l LABEL     card_label reported to apps (default: "Canon 4000D")
#   -q           apply in-camera quality settings first (white balance, ISO, sRGB,
#                Standard style); settings the camera won't accept are skipped
#   -r FILE      also record the untouched stream losslessly (-c:v copy) to FILE,
#                a .mkv/.mov/.avi name that must not exist yet
#   -h           show this help
# Env defaults: CANON_VIDEO_NR, CANON_DEVICE, CANON_LABEL, CANON_WB (Daylight),
# CANON_ISO (100); flags beat them. Stop with Ctrl-C, once.

set -u -o pipefail

VIDEO_NR="" DEVICE="" opt_n=0 opt_d=0 QUALITY=0 RECORD=""
LABEL="${CANON_LABEL:-Canon 4000D}" WB="${CANON_WB:-Daylight}" ISO="${CANON_ISO:-100}"
quality_settings=()

die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while getopts ':n:d:l:qr:h' opt; do
	case "$opt" in
	n) VIDEO_NR="$OPTARG" opt_n=1 ;;
	d) DEVICE="$OPTARG" opt_d=1 ;;
	l) LABEL="$OPTARG" ;;
	q) QUALITY=1 ;;
	r) RECORD="$OPTARG" ;;
	h) usage 0 ;;
	:) die "option -$OPTARG requires an argument" ;;
	*) die "unknown option -$OPTARG (try -h)" ;;
	esac
done

from_path=$opt_d
if [[ "$opt_d$opt_n" == 00 && -n "${CANON_DEVICE:-}" ]]; then
	DEVICE="$CANON_DEVICE" from_path=1
elif [[ "$opt_d$opt_n" == 00 ]]; then
	VIDEO_NR="${CANON_VIDEO_NR:-9}"
fi

if [[ "$from_path" -eq 1 ]]; then
	[[ "$DEVICE" =~ ^/dev/video(0|[1-9][0-9]*)$ ]] ||
		die "-d/CANON_DEVICE must be a /dev/videoN path, got '$DEVICE' (for a symlink, pass its target or use -n N)"
	VIDEO_NR="${BASH_REMATCH[1]}"
else
	[[ "$VIDEO_NR" =~ ^(0|[1-9][0-9]*)$ ]] ||
		die "-n/CANON_VIDEO_NR must be a number without leading zeros, got '$VIDEO_NR'"
	DEVICE="/dev/video${VIDEO_NR}"
fi

for cmd in gphoto2 ffmpeg setsid; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done

[[ -n "$RECORD" && -e "$RECORD" ]] && die "record file '$RECORD' already exists; pick a new name or remove it first"
case "$RECORD" in
"" | *.mkv | *.mov | *.avi | *.nut) : ;;
*) printf '%s: warning: MJPEG copies cleanly into .mkv/.mov/.avi; "%s" may be rejected by ffmpeg\n' \
	"${0##*/}" "$RECORD" >&2 ;;
esac

gphoto2 --auto-detect 2>/dev/null | grep -q 'usb:' ||
	die "no camera detected by gphoto2 --auto-detect (check cable / power / mode dial)"

command -v gio >/dev/null 2>&1 && gio mount -s gphoto2 >/dev/null 2>&1
pkill -x gvfsd-gphoto2 >/dev/null 2>&1 || true

if [[ "$QUALITY" -eq 1 ]]; then
	printf 'Applying quality settings (skips are non-fatal; check names with "gphoto2 --list-config"):\n'
	quality_settings=("whitebalance=$WB" "iso=$ISO" "colorspace=sRGB" "picturestyle=Standard")
fi
for kv in "${quality_settings[@]}"; do
	if gphoto2 --set-config "$kv" >/dev/null 2>&1; then
		printf '  set   %s\n' "$kv"
	else
		printf '  skip  %s\n' "$kv" >&2
	fi
done

loopback_sysfs=/sys/devices/virtual/video4linux
name_file="$loopback_sysfs/video${VIDEO_NR}/name"

if [[ -e "$DEVICE" && -r "$name_file" ]]; then
	printf 'Using existing loopback %s (%s)\n' "$DEVICE" "$(cat "$name_file")"
elif [[ -e "$DEVICE" ]]; then
	die "$DEVICE exists but isn't a v4l2loopback device (a real camera?); pick a free number with -n"
elif [[ -d /sys/module/v4l2loopback ]]; then
	existing=()
	for f in "$loopback_sysfs"/video*/name; do
		[[ -r "$f" ]] || continue
		d="${f%/name}"
		existing+=("/dev/${d##*/} ($(<"$f"))")
	done
	die "v4l2loopback is already loaded but has no $DEVICE, and modprobe can't add one to a loaded module.
  Existing loopback devices: ${existing[*]:-none}
  Either add it:  sudo v4l2loopback-ctl add -x 1 -n \"$LABEL\" $DEVICE
  or reload:      sudo modprobe -r v4l2loopback  (close apps using it first), then rerun
  or use an existing device that nothing else writes to, with -n N"
else
	printf 'Loading v4l2loopback for %s ...\n' "$DEVICE"
	sudo modprobe v4l2loopback exclusive_caps=1 card_label="$LABEL" video_nr="$VIDEO_NR" ||
		die "modprobe v4l2loopback failed (is v4l2loopback-dkms installed and built?)"
	# udev applies the uaccess ACL after the node appears, so wait for udev, then for write access.
	command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1
	for _ in {1..25}; do
		[[ -e "$DEVICE" && -w "$DEVICE" ]] && break
		sleep 0.2
	done
	[[ -e "$DEVICE" ]] || die "$DEVICE did not appear after loading v4l2loopback with video_nr=$VIDEO_NR"
fi

[[ -w "$DEVICE" ]] ||
	die "$DEVICE is not writable by $(id -un). Access normally comes from the uaccess ACL granted to the user on the active local seat (check: getfacl $DEVICE); run this from your desktop session, not over SSH or su. Fallback: add yourself to the 'video' group and log in again."

ff_out=(-map 0:v -vf "zscale=in_range=full:range=limited,format=yuv420p" -f v4l2 "$DEVICE")
if [[ -n "$RECORD" ]]; then
	ff_out+=(-map 0:v -c:v copy "$RECORD")
	printf 'Recording raw camera stream -> %s\n' "$RECORD"
fi

# Shutdown order: a stop request TERMs gphoto2 only, so ffmpeg reads EOF and finishes -r on its own.
STOP_GRACE=10 stop_signal="" launching=0
gp_pid="" gp_done=1 gp_status=0 gp_level=0 gp_at=0
ff_pid="" ff_done=1 ff_status=0 ff_level=0 ff_at=0

signal_child() {
	local -n c_pid="$1_pid" c_done="$1_done" c_level="$1_level" c_at="$1_at"
	local sig=TERM
	[[ -n "$c_pid" && "$c_done" -eq 0 && "$c_level" -lt "$2" ]] || return 0
	c_level=$((c_level + 1))
	# shellcheck disable=SC2034
	c_at=$SECONDS
	((c_level < $2)) || sig=KILL
	kill -s "$sig" "$c_pid" 2>/dev/null
	return 0
}

# shellcheck disable=SC2329
on_stop_signal() {
	[[ -n "$stop_signal" ]] || stop_signal="$1"
	if [[ "$launching" -eq 1 ]]; then
		signal_child gp 3
		signal_child ff 2
	elif [[ "$gp_done" -eq 0 ]]; then
		signal_child gp 3
	else
		signal_child ff 2
	fi
}

reap() {
	if [[ "$gp_done" -eq 0 && -n "$gp_pid" ]] && ! kill -0 "$gp_pid" 2>/dev/null; then
		wait "$gp_pid" 2>/dev/null
		gp_status=$?
		gp_done=1
	fi
	if [[ "$ff_done" -eq 0 && -n "$ff_pid" ]] && ! kill -0 "$ff_pid" 2>/dev/null; then
		wait "$ff_pid" 2>/dev/null
		ff_status=$?
		ff_done=1
	fi
}

supervise() {
	local released=0
	while :; do
		reap
		((gp_done == 0 || ff_done == 0)) || return 0
		if ((gp_done == 0 && ff_done == 1 && gp_level == 0)) ||
			((gp_done == 0 && (gp_level == 1 || gp_level == 2) && SECONDS - gp_at >= STOP_GRACE)); then
			signal_child gp 3
		fi
		if ((gp_done == 1 && released == 0)); then
			released=1
			ff_at=$SECONDS
			: 2>/dev/null <>"$fifo"
		fi
		((gp_done == 0 || ff_level == 2 || SECONDS - ff_at < STOP_GRACE)) || signal_child ff 2
		if ((gp_done == 0 && (gp_level == 1 || gp_level == 2))) ||
			((gp_done == 1 && ff_done == 0 && ff_level < 2)); then
			sleep 0.2
		else
			wait -n 2>/dev/null
			[[ $? -ne 127 ]] || sleep 0.2
		fi
	done
}

# A parent-death TERM covers this shell being SIGKILLed, since setsid keeps group signals off the children.
pdeath=()
if setpriv --pdeathsig TERM true >/dev/null 2>&1; then
	pdeath=(setpriv --pdeathsig TERM)
else
	printf '%s: warning: setpriv --pdeathsig unavailable; if this script is killed outright, gphoto2 and ffmpeg keep running\n' \
		"${0##*/}" >&2
fi

# shellcheck disable=SC2329
on_exit() {
	((${#pdeath[@]} > 0)) || signal_child gp 3
	rm -rf -- "$fifo_dir"
}

fifo_dir=$(mktemp -d -t canon-webcam.XXXXXX) || die "can't create a temporary directory"
fifo="$fifo_dir/live-view.mjpeg"
mkfifo -m 600 "$fifo" || die "can't create a FIFO in $fifo_dir"

trap 'on_stop_signal INT' INT
trap 'on_stop_signal TERM' TERM
trap 'on_stop_signal HUP' HUP
trap 'on_stop_signal QUIT' QUIT
trap on_exit EXIT

printf 'Streaming Canon live view -> %s  (Ctrl-C to stop)\n' "$DEVICE"

launching=1
if [[ -z "$stop_signal" ]]; then
	gp_done=0
	{
		trap '' PIPE
		exec setsid "${pdeath[@]}" gphoto2 --set-config output=PC --stdout --capture-movie
	} >"$fifo" &
	gp_pid=$!
	[[ -z "$stop_signal" || "$gp_level" -gt 0 ]] || signal_child gp 3
fi
if [[ -z "$stop_signal" ]]; then
	ff_done=0
	setsid "${pdeath[@]}" ffmpeg -hide_banner -loglevel warning -stats -f mjpeg -i - "${ff_out[@]}" <"$fifo" &
	ff_pid=$!
	[[ -z "$stop_signal" || "$ff_level" -gt 0 ]] || signal_child ff 2
fi
launching=0

supervise

if [[ -n "$stop_signal" ]]; then
	printf '\nStopped. %s left in place (remove with: sudo modprobe -r v4l2loopback).\n' "$DEVICE"
	exit $((128 + $(kill -l "$stop_signal")))
fi
printf '\nStream ended (gphoto2 exit %s, ffmpeg exit %s). %s left in place.\n' \
	"$gp_status" "$ff_status" "$DEVICE"
[[ "$ff_status" -ne 0 ]] && exit "$ff_status"
exit "$gp_status"
