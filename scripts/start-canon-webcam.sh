#!/usr/bin/env bash
#
# start-canon-webcam.sh — bridge a Canon EOS DSLR live-view feed onto a
# v4l2loopback device so any Linux app sees it as a plain webcam, and
# optionally record the untouched camera stream losslessly at the same time.
#
# Pipeline:  gphoto2 (USB live view, MJPEG)  ->  ffmpeg  ->  /dev/videoN
#                                                       \->  FILE (-c:v copy)
#
# Companion runbook: docs/canon-4000d-usb-webcam.md
#
# Usage:
#   start-canon-webcam.sh [-n VIDEO_NR] [-d /dev/videoN] [-l "Card Label"]
#                         [-q] [-r FILE]
#
#   -n VIDEO_NR   v4l2loopback device number to create/use   (default: 9)
#   -d DEVICE     explicit device path; overrides -n
#   -l LABEL      card_label reported to apps                 (default: "Canon 4000D")
#   -q            apply quality-oriented in-camera settings before streaming:
#                 fixed white balance, ISO 100, sRGB, Standard picture style.
#                 Non-fatal — settings the body or mode dial won't accept are
#                 skipped and listed.
#   -r FILE       also record the untouched camera stream to FILE alongside the
#                 webcam feed. Lossless (ffmpeg -c:v copy); use a .mkv/.mov/.avi
#                 name.
#   -h            show this help
#
# Env overrides: CANON_VIDEO_NR, CANON_DEVICE, CANON_LABEL,
#                CANON_WB   white balance used by -q   (default "Daylight")
#                CANON_ISO  ISO used by -q             (default "100")
#
# Needs: gphoto2, ffmpeg, v4l2loopback-dkms loaded (module load uses sudo).
# In-camera settings only take with the mode dial on M/Av/Tv/P; on Auto or a
# scene mode the camera locks them and -q simply skips them.
# Stop with Ctrl-C; the loopback device is left in place for the next run.

set -u -o pipefail

VIDEO_NR="${CANON_VIDEO_NR:-9}"
DEVICE="${CANON_DEVICE:-}"
LABEL="${CANON_LABEL:-Canon 4000D}"
WB="${CANON_WB:-Daylight}"
ISO="${CANON_ISO:-100}"
QUALITY=0
RECORD=""

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
	n) VIDEO_NR="$OPTARG" ;;
	d) DEVICE="$OPTARG" ;;
	l) LABEL="$OPTARG" ;;
	q) QUALITY=1 ;;
	r) RECORD="$OPTARG" ;;
	h) usage 0 ;;
	:) die "option -$OPTARG requires an argument" ;;
	*) die "unknown option -$OPTARG (try -h)" ;;
	esac
done

[[ "$VIDEO_NR" =~ ^[0-9]+$ ]] || die "VIDEO_NR must be a number, got '$VIDEO_NR'"
[[ -n "$DEVICE" ]] || DEVICE="/dev/video${VIDEO_NR}"

for cmd in gphoto2 ffmpeg; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done

if [[ -n "$RECORD" ]]; then
	case "$RECORD" in
	*.mkv | *.mov | *.avi | *.nut) : ;;
	*) printf '%s: warning: MJPEG copies cleanly into .mkv/.mov/.avi; "%s" may be rejected by ffmpeg\n' \
		"${0##*/}" "$RECORD" >&2 ;;
	esac
fi

# --- 1. make sure a camera is actually attached --------------------------------
if ! gphoto2 --auto-detect 2>/dev/null | grep -q 'usb:'; then
	die "no camera detected by gphoto2 --auto-detect (check cable / power / mode dial)"
fi

# --- 2. release the camera from the desktop auto-mount (gvfs) ------------------
# A mounted gphoto2 volume holds the USB device and makes capture fail with
# "Could not claim the USB device". Unmount it and stop the monitor helper.
if command -v gio >/dev/null 2>&1; then
	gio mount -s gphoto2 >/dev/null 2>&1 || true
fi
pkill -x gvfsd-gphoto2 >/dev/null 2>&1 || true

# --- 3. optional: quality-oriented in-camera settings ------------------------
# These are applied to the camera before live view starts; the live-view JPEG
# reflects them. Each is best-effort: a body that doesn't expose the option, or
# a mode dial position that locks it, makes gphoto2 exit non-zero and we move on.
if [[ "$QUALITY" -eq 1 ]]; then
	printf 'Applying quality settings (skips are non-fatal; check names with "gphoto2 --list-config"):\n'
	quality_settings=(
		"whitebalance=$WB"
		"iso=$ISO"
		"colorspace=sRGB"
		"picturestyle=Standard"
	)
	for kv in "${quality_settings[@]}"; do
		if gphoto2 --set-config "$kv" >/dev/null 2>&1; then
			printf '  set   %s\n' "$kv"
		else
			printf '  skip  %s\n' "$kv" >&2
		fi
	done
fi

# --- 4. ensure the v4l2loopback device exists -------------------------------
name_file="/sys/devices/virtual/video4linux/${DEVICE##*/}/name"

if [[ -e "$DEVICE" && -r "$name_file" ]]; then
	printf 'Using existing loopback %s (%s)\n' "$DEVICE" "$(cat "$name_file")"
else
	printf 'Loading v4l2loopback for %s ...\n' "$DEVICE"
	sudo modprobe v4l2loopback exclusive_caps=1 card_label="$LABEL" video_nr="$VIDEO_NR" ||
		die "modprobe v4l2loopback failed (is v4l2loopback-dkms installed and built?)"
	# modprobe returns before udev has created the node; wait briefly.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[[ -e "$DEVICE" ]] && break
		sleep 0.3
	done
	[[ -e "$DEVICE" ]] || die "$DEVICE did not appear after loading v4l2loopback"
fi

[[ -w "$DEVICE" ]] || die "$DEVICE is not writable by $(id -un) (add yourself to the 'video' group)"

# --- 5. run the bridge (+ optional lossless recording) ---------------------
# One MJPEG input, one or two outputs: decoded/converted into the loopback for
# apps, and (with -r) the original packets copied verbatim to a file.
ff_out=(-map 0:v -vf format=yuv420p -f v4l2 "$DEVICE")
if [[ -n "$RECORD" ]]; then
	ff_out+=(-map 0:v -c:v copy "$RECORD")
	printf 'Recording raw camera stream -> %s\n' "$RECORD"
fi

cleaned_up=0
cleanup() {
	trap - INT TERM EXIT
	[[ "$cleaned_up" -eq 1 ]] && return
	cleaned_up=1
	pkill -P $$ >/dev/null 2>&1 || true
	printf '\nStopped. %s left in place (remove with: sudo modprobe -r v4l2loopback).\n' "$DEVICE"
}
trap cleanup INT TERM EXIT

printf 'Streaming Canon live view -> %s  (Ctrl-C to stop)\n' "$DEVICE"

gphoto2 --set-config output=PC --stdout --capture-movie |
	ffmpeg -hide_banner -loglevel warning -stats -f mjpeg -i - "${ff_out[@]}" &
bridge_pid=$!
wait "$bridge_pid"
status=$?
trap - INT TERM EXIT
cleanup
exit "$status"
