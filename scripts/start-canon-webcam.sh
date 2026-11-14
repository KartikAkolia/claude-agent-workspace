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
#   -d DEVICE     explicit /dev/videoN path; overrides -n, and its N is the
#                 number loaded. Other forms (symlinks etc.) are rejected.
#   -l LABEL      card_label reported to apps                 (default: "Canon 4000D")
#   -q            apply quality-oriented in-camera settings before streaming:
#                 fixed white balance, ISO 100, sRGB, Standard picture style.
#                 Non-fatal — settings the body or mode dial won't accept are
#                 skipped and listed.
#   -r FILE       also record the untouched camera stream to FILE alongside the
#                 webcam feed. Lossless (ffmpeg -c:v copy); use a .mkv/.mov/.avi
#                 name. FILE must not exist yet; the script refuses to start.
#   -h            show this help
#
# Env defaults: CANON_VIDEO_NR, CANON_DEVICE, CANON_LABEL,
#               CANON_WB   white balance used by -q   (default "Daylight")
#               CANON_ISO  ISO used by -q             (default "100")
# A flag always beats the environment. For the device: -d, then -n, then
# CANON_DEVICE, then CANON_VIDEO_NR, then 9.
#
# Needs: gphoto2, ffmpeg, setsid and (optionally) setpriv from util-linux,
# v4l2loopback-dkms loaded (module load uses sudo).
# In-camera settings only take with the mode dial on M/Av/Tv/P; on Auto or a
# scene mode the camera locks them and -q simply skips them.
# Stop with Ctrl-C, once: the script asks gphoto2 to end live view, ffmpeg
# finishes writing when the feed ends, and the script exits when both are
# done. A second Ctrl-C makes gphoto2 abort, a third kills it. The loopback
# device is left in place for the next run.

set -u -o pipefail

VIDEO_NR=""
DEVICE=""
opt_n=0 # set by -n / -d, so an explicit flag beats CANON_DEVICE
opt_d=0
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
	n)
		VIDEO_NR="$OPTARG"
		opt_n=1
		;;
	d)
		DEVICE="$OPTARG"
		opt_d=1
		;;
	l) LABEL="$OPTARG" ;;
	q) QUALITY=1 ;;
	r) RECORD="$OPTARG" ;;
	h) usage 0 ;;
	:) die "option -$OPTARG requires an argument" ;;
	*) die "unknown option -$OPTARG (try -h)" ;;
	esac
done

# Flags beat the environment: -d, then -n, then CANON_DEVICE, then
# CANON_VIDEO_NR, then 9.
if [[ "$opt_d" -eq 1 ]]; then
	from_path=1
elif [[ "$opt_n" -eq 1 ]]; then
	from_path=0
elif [[ -n "${CANON_DEVICE:-}" ]]; then
	DEVICE="$CANON_DEVICE"
	from_path=1
else
	VIDEO_NR="${CANON_VIDEO_NR:-9}"
	from_path=0
fi

# modprobe and v4l2loopback-ctl take the device number, not a path, so with
# -d (or CANON_DEVICE) the number comes from the path. Otherwise -d /dev/video5
# would load video_nr=9 and then wait for a /dev/video5 that never appears.
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

if [[ -n "$RECORD" ]]; then
	# Without -y, ffmpeg won't overwrite FILE, and with stdin taken by the
	# camera feed it can't ask either: it logs "already exists. Exiting." and
	# exits 0, taking the webcam feed down with it. Refuse before starting.
	if [[ -e "$RECORD" ]]; then
		die "record file '$RECORD' already exists; pick a new name or remove it first"
	fi
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
loopback_sysfs=/sys/devices/virtual/video4linux
name_file="$loopback_sysfs/video${VIDEO_NR}/name"

if [[ -e "$DEVICE" && -r "$name_file" ]]; then
	printf 'Using existing loopback %s (%s)\n' "$DEVICE" "$(cat "$name_file")"
elif [[ -e "$DEVICE" ]]; then
	die "$DEVICE exists but isn't a v4l2loopback device (a real camera?); pick a free number with -n"
elif [[ -d /sys/module/v4l2loopback ]]; then
	# modprobe on a module that's already loaded succeeds without doing
	# anything, so it can't create the device -- e.g. when OBS's virtual
	# camera, or an earlier run with another -n, loaded it first.
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
	# The kernel creates the node during modprobe, but devtmpfs makes it
	# root-only (0600). udev then applies its group and the uaccess ACL that
	# actually lets the desktop user open it, a moment later -- so waiting
	# for the node to exist isn't enough. Wait for udev to finish, then poll
	# briefly for write access in case the event hadn't been queued yet.
	if command -v udevadm >/dev/null 2>&1; then
		udevadm settle --timeout=10 >/dev/null 2>&1 || true
	fi
	for _ in {1..25}; do
		[[ -e "$DEVICE" && -w "$DEVICE" ]] && break
		sleep 0.2
	done
	[[ -e "$DEVICE" ]] || die "$DEVICE did not appear after loading v4l2loopback with video_nr=$VIDEO_NR"
fi

# Desktop users normally get access from udev's uaccess ACL, which logind
# grants only to the user on the active local seat (not over SSH or su).
[[ -w "$DEVICE" ]] ||
	die "$DEVICE is not writable by $(id -un). Access normally comes from the uaccess ACL granted to the user on the active local seat (check: getfacl $DEVICE); run this from your desktop session, not over SSH or su. Fallback: add yourself to the 'video' group and log in again."

# --- 5. run the bridge (+ optional lossless recording) ---------------------
# One MJPEG input, one or two outputs: decoded/converted into the loopback for
# apps, and (with -r) the original packets copied verbatim to a file.
# MJPEG decodes to the legacy full-range yuvj420p pixel format, which the
# v4l2 muxer rejects outright ("Unknown V4L2 pixel format equivalent for
# yuvj420p") -- converting to yuv420p is required, not optional. Doing that
# conversion via plain `format=yuv420p` works but routes through libswscale's
# deprecated yuvj* handling and logs "deprecated pixel format used, make sure
# you did set range correctly" on every run. zscale (libzimg, not swscale)
# does the identical full->limited range remap without that code path.
ff_out=(-map 0:v -vf "zscale=in_range=full:range=limited,format=yuv420p" -f v4l2 "$DEVICE")
if [[ -n "$RECORD" ]]; then
	ff_out+=(-map 0:v -c:v copy "$RECORD")
	printf 'Recording raw camera stream -> %s\n' "$RECORD"
fi

# Shutdown. gphoto2 and ffmpeg run in their own sessions (setsid), so the
# terminal's own signals (Ctrl-C's SIGINT, a hangup's SIGHUP) reach only this
# script, and the script is the one place that signals the children (Ctrl-Z
# likewise suspends only the script; the stream keeps running).
#
# The shutdown is ordered: a stop request (INT, TERM, HUP or QUIT) signals
# only gphoto2, with one SIGTERM, which it handles like Ctrl-C by ending live
# view. Its end of the FIFO then closes, and ffmpeg reads EOF and finishes
# the -r recording on its own. Signalling ffmpeg at the same time would make
# it stop reading at once, and gphoto2's next frame write would then fail.
# TERM rather than INT because, as async commands of a non-interactive shell,
# the children start with SIGINT ignored until the program installs its own
# handler: an INT sent before that (or before the exec) would be lost.
#
# Each child has its own escalation, so a stalled gphoto2 can't take ffmpeg
# down with it. gphoto2: another stop request, or STOP_GRACE seconds without
# exiting, sends a second TERM (its "Aborting..." path, which tears the
# camera down from inside the signal handler), then KILL. ffmpeg is signalled
# only once gphoto2 is gone and it still hasn't exited STOP_GRACE seconds
# later (TERM, then KILL); a stop request at that point moves it on at once.
# If ffmpeg exits first (an error, or it ended early), gphoto2 gets its one
# TERM straight away rather than feeding a FIFO nobody reads.
STOP_GRACE=10
stop_signal="" # first stop signal the script got: INT, TERM, HUP or QUIT
gp_pid=""
ff_pid=""
gp_done=1 # 0 from launch until the child has exited and been reaped
ff_done=1
gp_status=0
ff_status=0
gp_level=0  # signals sent to gphoto2: 1, 2 = TERM; 3 = KILL
ff_level=0  # signals sent to ffmpeg:  1 = TERM;    2 = KILL
gp_at=0     # $SECONDS of gphoto2's latest signal
ff_at=0     # $SECONDS when ffmpeg's clock last started
launching=0 # 1 while the children are being started

# One step along gphoto2's ladder: TERM, TERM, KILL.
signal_gp() {
	[[ -n "$gp_pid" && "$gp_done" -eq 0 && "$gp_level" -lt 3 ]] || return 0
	gp_level=$((gp_level + 1))
	gp_at=$SECONDS
	if ((gp_level < 3)); then
		kill -s TERM "$gp_pid" 2>/dev/null
	else
		kill -s KILL "$gp_pid" 2>/dev/null
	fi
	return 0
}

# One step along ffmpeg's ladder: TERM, KILL.
signal_ff() {
	[[ -n "$ff_pid" && "$ff_done" -eq 0 && "$ff_level" -lt 2 ]] || return 0
	ff_level=$((ff_level + 1))
	ff_at=$SECONDS
	if ((ff_level < 2)); then
		kill -s TERM "$ff_pid" 2>/dev/null
	else
		kill -s KILL "$ff_pid" 2>/dev/null
	fi
	return 0
}

# Called from the traps below, which ShellCheck can't see.
# shellcheck disable=SC2329
on_stop_signal() { # $1: INT, TERM, HUP or QUIT
	[[ -n "$stop_signal" ]] || stop_signal="$1"
	# A child whose PID isn't known yet is skipped here; the launch code
	# hands it the TERM it missed.
	if [[ "$launching" -eq 1 ]]; then
		# Neither child has got going yet, so there's nothing to finish
		# in order: stop both.
		signal_gp
		signal_ff
	elif [[ "$gp_done" -eq 0 ]]; then
		signal_gp
	else
		signal_ff
	fi
}

# Marks children that have exited and collects their exit statuses (bash has
# already reaped them, so these waits return at once).
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

# Waits for both children, enforcing the shutdown order and grace periods.
supervise() {
	local released=0
	while :; do
		reap
		if [[ "$gp_done" -eq 0 ]]; then
			if [[ "$ff_done" -eq 1 && "$gp_level" -eq 0 ]]; then
				signal_gp # ffmpeg is gone: end live view now
			elif ((gp_level == 1 || gp_level == 2)) && ((SECONDS - gp_at >= STOP_GRACE)); then
				signal_gp
			fi
		elif [[ "$ff_done" -eq 0 ]]; then
			if [[ "$released" -eq 0 ]]; then
				# gphoto2 is gone, so ffmpeg should see EOF. If gphoto2
				# was stopped before it even opened the FIFO, ffmpeg's
				# side would still be blocked opening it: open and close
				# the FIFO once so that open completes and reads EOF.
				released=1
				ff_at=$SECONDS
				: 2>/dev/null <>"$fifo"
			fi
			((ff_level == 2 || SECONDS - ff_at < STOP_GRACE)) || signal_ff
		else
			return 0
		fi
		# Poll while a grace period is running; otherwise sleep until a
		# child exits or a trap runs.
		if ((gp_done == 0 && (gp_level == 1 || gp_level == 2))) ||
			((gp_done == 1 && ff_done == 0 && ff_level < 2)); then
			sleep 0.2
		else
			wait -n 2>/dev/null
			# 127: no unreported child left, though one looks alive.
			[[ $? -ne 127 ]] || sleep 0.2
		fi
	done
}

# Because setsid takes the children out of this script's process group, a
# signal aimed at the group reaches only the script. Its traps forward
# INT/TERM/HUP/QUIT, but nothing can forward SIGKILL (kill -9, an OOM kill,
# a launcher killing the group). So each child also gets a parent-death
# signal: when this shell dies for any reason, the kernel sends each
# still-running child one SIGTERM (ffmpeg then finishes the recording, and
# gphoto2, with SIGPIPE ignored, isn't killed by the closed FIFO). setpriv
# runs after setsid, because a fork would clear the setting, and it survives
# the exec of gphoto2/ffmpeg (neither is setuid). The children's direct
# parent stays this single-threaded shell.
pdeath=()
if setpriv --pdeathsig TERM true >/dev/null 2>&1; then
	pdeath=(setpriv --pdeathsig TERM)
else
	printf '%s: warning: setpriv --pdeathsig unavailable; if this script is killed outright, gphoto2 and ffmpeg keep running\n' \
		"${0##*/}" >&2
fi

# Called from the EXIT trap below: if the script exits early, stop gphoto2
# (ffmpeg then reads EOF), and remove the FIFO. With a parent-death signal
# the kernel already sends that TERM as this shell exits; a second one from
# here would trip gphoto2's abort path.
# shellcheck disable=SC2329
on_exit() {
	((${#pdeath[@]} > 0)) || signal_gp
	rm -rf -- "$fifo_dir"
}

# gphoto2 and ffmpeg are joined by a private FIFO rather than a `|` pipeline:
# bash only waits for a background pipeline as a whole, so its two PIDs
# can't be waited for, or report a status, separately.
fifo_dir=$(mktemp -d -t canon-webcam.XXXXXX) || die "can't create a temporary directory"
fifo="$fifo_dir/live-view.mjpeg"
mkfifo -m 600 "$fifo" || die "can't create a FIFO in $fifo_dir"

trap 'on_stop_signal INT' INT
trap 'on_stop_signal TERM' TERM
trap 'on_stop_signal HUP' HUP
trap 'on_stop_signal QUIT' QUIT
trap on_exit EXIT

printf 'Streaming Canon live view -> %s  (Ctrl-C to stop)\n' "$DEVICE"

# A stop request can arrive anywhere in here. Each child is started only if
# none has arrived yet; until supervise starts, a request stops both (see
# on_stop_signal), and one that arrives between a child's `&` and its PID
# assignment is caught up right after, unless that child already had it.
# A child stopped this early hasn't got going as gphoto2/ffmpeg yet (each
# blocks opening the FIFO until the other end opens), so its SIGTERM ends it
# before it touches the camera or files.
#
# gphoto2 runs with SIGPIPE ignored: if ffmpeg goes away first, a frame write
# then fails with EPIPE instead of killing gphoto2 outright. libgphoto2
# returns that as an I/O error, and gphoto2's capture loop exits through its
# normal path, which ends live view.
#
# setsid only forks when it's a process group leader, which a background job
# of a shell without job control isn't, and setpriv and the brace group's
# exec don't fork either, so these PIDs are gphoto2's and ffmpeg's own and
# this shell is their parent.
launching=1
if [[ -z "$stop_signal" ]]; then
	gp_done=0
	{
		trap '' PIPE
		exec setsid "${pdeath[@]}" gphoto2 --set-config output=PC --stdout --capture-movie
	} >"$fifo" &
	gp_pid=$!
	[[ -z "$stop_signal" || "$gp_level" -gt 0 ]] || signal_gp
fi
if [[ -z "$stop_signal" ]]; then
	ff_done=0
	setsid "${pdeath[@]}" ffmpeg -hide_banner -loglevel warning -stats -f mjpeg -i - "${ff_out[@]}" <"$fifo" &
	ff_pid=$!
	[[ -z "$stop_signal" || "$ff_level" -gt 0 ]] || signal_ff
fi
launching=0

supervise

if [[ -n "$stop_signal" ]]; then
	printf '\nStopped. %s left in place (remove with: sudo modprobe -r v4l2loopback).\n' "$DEVICE"
	exit $((128 + $(kill -l "$stop_signal")))
fi
printf '\nStream ended (gphoto2 exit %s, ffmpeg exit %s). %s left in place.\n' \
	"$gp_status" "$ff_status" "$DEVICE"
# As with pipefail: the rightmost non-zero status.
[[ "$ff_status" -ne 0 ]] && exit "$ff_status"
exit "$gp_status"
