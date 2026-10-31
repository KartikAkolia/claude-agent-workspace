#!/usr/bin/env bash
# Disable device power saving on asus-vivobook (Arch, GRUB, mkinitcpio).
# Keep this file beside device-power-saving-config.py. Requires Python 3,
# NetworkManager, iw and kmod. Suspend, hibernate and lid policy are untouched.
# Run: scripts/disable-device-power-saving.sh
# Undo: scripts/disable-device-power-saving.sh --undo BACKUP_DIRECTORY
# Each successful run prints its private backup path. Undo runs in reverse order.
# Undo preserves unrelated later GRUB edits and refuses conflicting file/profile
# edits. Reboot after install OR undo; live sysfs values persist until reboot.
# Recovery after an incomplete rollback: --recover BACKUP_DIRECTORY.
# Requires the modconf hook in mkinitcpio presets for early-loaded modules.
# Needs enough space under /var/lib to snapshot /boot before each run.
# GRUB defaults must have one literal quoted assignment (no expansions).
# Do not delete backup directories until their runs have been undone. A run
# directory holding an "aborted" file, or an empty one, failed before any
# change and can go.
# Failed installs restore config, profiles and existing /boot files. Backups
# remain for recovery, including failed rollback. This is not power-loss atomic.
set -euo pipefail

if ((EUID != 0)); then
	exec sudo -- bash "$0" "$@"
fi
umask 077
readonly STATE_ROOT=/var/lib/device-power-saving
readonly GRUB_FILE=/etc/default/grub
readonly BOOT_DIR=/boot
# Presets writing outside /boot need their own backup before using this script.
HELPER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/device-power-saving-config.py"
readonly HELPER
readonly FILES=(/etc/udev/rules.d/99-no-runtime-pm.rules /etc/modprobe.d/no-power-saving.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf "$GRUB_FILE")
die() {
	echo "error: $*" >&2
	exit 1
}
for tool in python3 grub-mkconfig mkinitcpio modprobe nmcli iw udevadm flock; do
	command -v "$tool" >/dev/null || die "$tool not found"
done
[[ -f $HELPER ]] || die "missing $HELPER"
mkdir -p "$STATE_ROOT"
exec 9>"$STATE_ROOT/lock"
flock -n 9 || die "another power-policy operation is running"

# Copy beside a destination, retaining metadata, then rename. Failed staging
# never truncates a live file; EXIT cleans abandoned sibling staging files.
place() (
	local source=$1 destination=$2 staged
	staged=$(mktemp "$(dirname "$destination")/.device-power.XXXXXX") || return
	trap 'rm -f -- "$staged"' EXIT
	cp --preserve=all -- "$source" "$staged" || return
	mv -fT -- "$staged" "$destination"
)
# Call only as a plain assignment (value=$(profile_value ...)) so errexit
# propagates its die; inside [[ ]] or with || a failure would be masked.
profile_value() {
	local raw value rc=0
	raw=$(LC_ALL=C nmcli -g 802-11-wireless.powersave connection show uuid "$1" </dev/null) || rc=$?
	value=${raw%% *}
	# nmcli 1.58 -g prints the enum name (e.g. "disable"). A leading number,
	# as in "2 (disable)", is accepted too.
	case $value in
	default) value=0 ;;
	ignore) value=1 ;;
	disable) value=2 ;;
	enable) value=3 ;;
	esac
	if ((rc)); then
		printf 'nmcli failed (exit %d) reading %s\n' "$rc" "$1" >&2
	elif [[ ! $value =~ ^[0-3]$ ]]; then
		printf 'unrecognised nmcli powersave output for %s: %q\n' "$1" "$raw" >&2
	fi
	((rc == 0)) && [[ $value =~ ^[0-3]$ ]] || die "cannot read Wi-Fi policy for $1"
	printf '%s\n' "$value"
}
# Die with a distinct message when the profile can't be read, so a parse
# failure is never reported as a policy change.
# Same rule as profile_value: call only as a plain command, never under || or if.
require_disabled() {
	local now
	now=$(profile_value "$1")
	[[ $now == 2 ]] || die "$2"
}
restore_profiles() {
	local uuid value failed=0
	while read -r uuid value; do
		nmcli connection modify uuid "$uuid" 802-11-wireless.powersave "$value" </dev/null || failed=1
	done <"$1/profiles"
	return "$failed"
}
restore_files() {
	local dir=$1 i failed=0
	for i in "${!FILES[@]}"; do
		if [[ -f $dir/before/$i ]]; then
			place "$dir/before/$i" "${FILES[i]}" || failed=1
		else
			rm -f -- "${FILES[i]}" || failed=1
		fi
	done
	return "$failed"
}
# Restore transaction bookkeeping if final publication itself failed.
restore_cursor() {
	local dir=$1 parent
	parent=$(cat "$dir/parent") || return
	rm -f -- "$dir/complete" || return
	if [[ -f $dir/undo-source ]]; then
		rm -f -- "$(cat "$dir/undo-source")/undone" || return
	fi
	if [[ -n $parent ]]; then
		ln -sfnT "$parent" "$STATE_ROOT/current"
	else
		rm -f -- "$STATE_ROOT/current"
	fi
}
# phase: none, then snapshot once this invocation has created its own run
# directory, then pending from just before the first managed write until the
# run completes. finish restores on pending, and on snapshot drops the bulky
# /boot copy, keeping the rest for diagnosis.
backup='' phase=none
finish() {
	local status=$? failed=false
	trap - EXIT INT TERM HUP
	if [[ $phase == pending ]]; then
		echo "Installation failed; restoring from $backup" >&2
		restore_files "$backup" || failed=true
		restore_profiles "$backup" || failed=true
		# Restore all pre-existing boot artifacts, including images partially
		# overwritten by a failed mkinitcpio. Old grub.cfg references old images.
		cp -a -- "$backup/boot/." "$BOOT_DIR/" || failed=true
		restore_cursor "$backup" || failed=true
		udevadm control --reload || failed=true
		nmcli general reload conf || failed=true
		if $failed; then
			echo "RECOVERY INCOMPLETE: do not reboot; retry: $0 --recover $backup" >&2
		else
			rm -f -- "$backup/pending"
			echo "Previous config, profiles and boot files restored; backup: $backup" >&2
		fi
		status=1
	elif [[ $status != 0 && $phase == snapshot ]]; then
		if rm -rf -- "${backup:?}/boot" && rm -f -- "$backup/pending" && touch "$backup/aborted"; then
			echo "Nothing was changed; partial run kept for diagnosis: $backup" >&2
		else
			echo "Nothing was changed; could not tidy partial run $backup" >&2
		fi
	fi
	exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ ${1:-} == --recover ]]; then
	[[ $# == 2 ]] || die "usage: $0 --recover BACKUP_DIRECTORY"
	backup=$(readlink -f "$2")
	[[ $backup == "$STATE_ROOT"/run.* && -f $backup/before/3 && -d $backup/boot && -f $backup/profiles && -f $backup/parent && -f $backup/pending && ! -f $backup/complete ]] || die "not an incomplete recovery backup"
	# Recovery restores whole snapshots; unlike undo, run this immediately,
	# before making other changes. Reuse the normal error cleanup on failure.
	phase=pending
	restore_files "$backup"
	restore_profiles "$backup"
	cp -a -- "$backup/boot/." "$BOOT_DIR/"
	restore_cursor "$backup"
	udevadm control --reload
	nmcli general reload conf
	phase=none
	rm -f -- "$backup/pending"
	echo "Recovered $backup. Reboot before relying on device policy."
	exit 0
fi

# Do not snapshot a partially recovered policy as a new starting state.
for previous in "$STATE_ROOT"/run.*/pending; do
	[[ ! -f $previous || -f ${previous%/pending}/complete ]] ||
		die "unfinished recovery; run: $0 --recover ${previous%/pending}"
done

if [[ ${1:-} == --undo ]]; then
	[[ $# == 2 ]] || die "usage: $0 --undo BACKUP_DIRECTORY"
	backup=$(readlink -f "$2")
	[[ $backup == "$STATE_ROOT"/run.* && -f $backup/complete && ! -e $backup/undone ]] || die "not a completed, unconsumed backup"
	[[ $(readlink -f "$STATE_ROOT/current") == "$backup" ]] || die "undo the most recent run first"
	# Refuse undo out of order and preserve later user edits rather than
	# overwriting them with an old whole-file snapshot.
	for i in 0 1 2; do
		cmp -s "${FILES[i]}" "$backup/after/$i" || die "${FILES[i]} changed; reconcile it before undo"
	done
	while read -r uuid value; do
		require_disabled "$uuid" "Wi-Fi profile $uuid changed; reconcile it before undo"
	done <"$backup/profiles"
	python3 "$HELPER" undo-grub "$GRUB_FILE" "$backup/before/3" >"$backup/undo-grub"
	# An undo is itself recoverable. Snapshot its starting config and boot
	# files before touching them; retain the original backup for retries.
	source_backup=$backup
	backup=$(mktemp -d "$STATE_ROOT/run.XXXXXX")
	phase=snapshot
else
	[[ $# == 0 ]] || die "usage: $0 [--undo|--recover BACKUP_DIRECTORY]"
	backup=$(mktemp -d "$STATE_ROOT/run.XXXXXX")
	phase=snapshot
fi
: >"$backup/parent"
[[ ! -L $STATE_ROOT/current ]] || readlink -f "$STATE_ROOT/current" >"$backup/parent"
mkdir "$backup/before" "$backup/after"
for i in "${!FILES[@]}"; do
	file=${FILES[i]}
	[[ -d $(dirname "$file") ]] || die "missing configuration directory for $file"
	[[ ! -L $file && (! -e $file || -f $file) ]] || die "refusing non-regular configuration: $file"
	[[ ! -f $file ]] || cp -a -- "$file" "$backup/before/$i"
done
[[ -f $backup/before/3 && -f $BOOT_DIR/grub/grub.cfg ]] || die "GRUB defaults or generated config missing"
# Snapshot all /boot outputs: mkinitcpio presets may use custom image names.
# Sufficient space is required; a failed snapshot precedes all managed writes.
cp -a -- "$BOOT_DIR" "$backup/boot"
: >"$backup/profiles"
LC_ALL=C nmcli -t -f UUID,TYPE connection show </dev/null >"$backup/profile-list"
while IFS=: read -r uuid type; do
	[[ $type == 802-11-wireless || $type == wifi ]] || continue
	value=$(profile_value "$uuid")
	printf '%s %s\n' "$uuid" "$value" >>"$backup/profiles"
done <"$backup/profile-list"

if [[ -n ${source_backup:-} ]]; then
	cp -a -- "$source_backup/undo-grub" "$backup/new-grub"
else
	python3 "$HELPER" grub "$GRUB_FILE" >"$backup/new-grub"
fi
# Retain permissions, owner and labels of the GRUB defaults.
cp --attributes-only --preserve=all "$GRUB_FILE" "$backup/new-grub"
bash -n "$backup/new-grub"
[[ -z ${source_backup:-} ]] || printf '%s\n' "$source_backup" >"$backup/undo-source"
# Still snapshot while creating the marker: if touch fails, finish only tidies.
# An exit between the two lines also tidies, removing the marker with /boot.
touch "$backup/pending"
phase=pending
if [[ -n ${source_backup:-} ]]; then
	for i in 0 1 2; do
		if [[ -f $source_backup/before/$i ]]; then
			place "$source_backup/before/$i" "${FILES[i]}"
		else
			rm -f -- "${FILES[i]}"
		fi
	done
	restore_profiles "$source_backup"
else
	cat >"$backup/after/0" <<'EOF'
# Installed by disable-device-power-saving.sh
ACTION=="add|bind", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add|bind", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="on"
EOF
	cat >"$backup/after/1" <<'EOF'
# Installed by disable-device-power-saving.sh
options snd_hda_intel power_save=0 power_save_controller=N
options nvidia NVreg_DynamicPowerManagement=0x00
options iwlmvm power_scheme=1
EOF
	cat >"$backup/after/2" <<'EOF'
# Installed by disable-device-power-saving.sh
[connection]
wifi.powersave=2
EOF
	for i in 0 1 2; do
		chmod 644 "$backup/after/$i"
		if [[ -f $backup/before/$i ]]; then
			cp --attributes-only --preserve=all "$backup/before/$i" "$backup/after/$i"
		fi
		place "$backup/after/$i" "${FILES[i]}"
	done
	modprobe --showconfig >"$backup/effective-modules"
	python3 "$HELPER" modules <"$backup/effective-modules"
	while read -r uuid value; do
		nmcli connection modify uuid "$uuid" 802-11-wireless.powersave 2 </dev/null
		require_disabled "$uuid" "Wi-Fi profile $uuid did not retain the policy"
	done <"$backup/profiles"
fi
place "$backup/new-grub" "$GRUB_FILE"
# Build images first. A failure in either build restores the /boot snapshot.
mkinitcpio -P
grub-mkconfig -o "$BOOT_DIR/grub/grub.cfg"
if [[ -z ${source_backup:-} ]]; then
	python3 "$HELPER" boot <"$BOOT_DIR/grub/grub.cfg"
fi
udevadm control --reload
nmcli general reload conf
if [[ -n ${source_backup:-} ]]; then
	touch "$source_backup/undone"
	parent=$(cat "$source_backup/parent")
	if [[ -n $parent && -d $parent ]]; then
		ln -sfnT "$parent" "$STATE_ROOT/current"
	else
		rm -f "$STATE_ROOT/current"
	fi
else
	cp -a -- "$GRUB_FILE" "$backup/after/3"
	touch "$backup/complete"
	ln -sfnT "$backup" "$STATE_ROOT/current"
fi
phase=none
rm -f -- "$backup/pending"

if [[ -n ${source_backup:-} ]]; then
	echo "Undo complete. Reboot to restore device policy, including loaded udev/sysfs and Wi-Fi state."
else
	# Live application is best effort. No new boot-time failure can follow it.
	echo -1 >/sys/module/usbcore/parameters/autosuspend || true
	for ctl in /sys/bus/usb/devices/*/power/control /sys/bus/pci/devices/*/power/control; do
		[[ ! -e $ctl ]] || echo on >"$ctl" || true
	done
	echo performance >/sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
	for spec in power_save:0 power_save_controller:N; do
		file=/sys/module/snd_hda_intel/parameters/${spec%:*}
		[[ ! -e $file ]] || echo "${spec#*:}" >"$file" || true
	done
	for dev in /sys/class/net/*/wireless; do
		[[ -e $dev ]] || continue
		iface=${dev%/wireless}
		iw dev "${iface##*/}" set power_save off || echo "Reboot needed for Wi-Fi policy on ${iface##*/}" >&2
	done
	echo "Done. Reboot for full device policy. Undo: $0 --undo $backup"
fi
