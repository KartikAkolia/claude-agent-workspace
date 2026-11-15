#!/usr/bin/env bash
# Disable runtime PM, PCIe ASPM and Wi-Fi power saving on asus-vivobook (Arch,
# GRUB, mkinitcpio), keeping a recoverable backup per run. Needs
# device-power-saving-config.py beside it. Reboot after install or undo.
# Usage: disable-device-power-saving.sh [--undo BACKUP_DIRECTORY | --recover BACKUP_DIRECTORY]
# Docs: docs/device-power-saving.md
set -euo pipefail

((EUID == 0)) || exec sudo -- bash "$0" "$@"
umask 077
readonly STATE_ROOT=/var/lib/device-power-saving
readonly GRUB_FILE=/etc/default/grub
readonly BOOT_DIR=/boot
HELPER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/device-power-saving-config.py"
readonly HELPER
# Backups store files by index: append only, and keep GRUB at 3.
readonly FILES=(/etc/udev/rules.d/99-no-runtime-pm.rules /etc/modprobe.d/no-power-saving.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf "$GRUB_FILE"
	/etc/systemd/system/device-power-late.service /etc/systemd/system/multi-user.target.d/device-power-late.conf /usr/local/sbin/device-power-late
	/etc/systemd/system/suspend.target.d/device-power-late.conf)
readonly MANAGED=(0 1 2 4 5 6 7)
readonly KEEP_ATTRS=(--preserve=all --no-preserve=timestamps)
die() {
	echo "error: $*" >&2
	exit 1
}
for tool in python3 grub-mkconfig mkinitcpio modprobe nmcli iw udevadm flock setpci systemctl; do
	command -v "$tool" >/dev/null || die "$tool not found"
done
[[ -f $HELPER ]] || die "missing $HELPER"
mkdir -p "$STATE_ROOT"
exec 9>"$STATE_ROOT/lock"
flock -n 9 || die "another power-policy operation is running"

place() (
	local source=$1 destination=$2 staged
	staged=$(mktemp "$(dirname "$destination")/.device-power.XXXXXX") || return
	trap 'rm -f -- "$staged"' EXIT
	cp "${KEEP_ATTRS[@]}" -- "$source" "$staged" || return
	mv -fT -- "$staged" "$destination"
)
restore_one() {
	if [[ -f $1 ]]; then
		place "$1" "$2"
	else
		rm -f -- "$2"
	fi
}
# Call only as a plain assignment: under if, || or [[ ]] its die would be masked.
profile_value() {
	local raw value rc=0
	raw=$(LC_ALL=C nmcli -g 802-11-wireless.powersave connection show uuid "$1" </dev/null) || rc=$?
	value=${raw%% *}
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
	local i failed=0
	for i in "${!FILES[@]}"; do
		restore_one "$1/before/$i" "${FILES[i]}" || failed=1
	done
	return "$failed"
}
restore_cursor() {
	local dir=$1 parent
	parent=$(cat "$dir/parent") || return
	rm -f -- "$dir/complete" || return
	[[ ! -f $dir/undo-source ]] || rm -f -- "$(cat "$dir/undo-source")/undone" || return
	if [[ -n $parent ]]; then
		ln -sfnT "$parent" "$STATE_ROOT/current"
	else
		rm -f -- "$STATE_ROOT/current"
	fi
}
backup='' phase=none
finish() {
	local status=$? failed=false
	trap - EXIT INT TERM HUP
	if [[ $status != 0 && $phase == snapshot ]] && rm -rf -- "${backup:?}/boot" &&
		rm -f -- "$backup/pending" && touch "$backup/aborted"; then
		echo "Nothing was changed; partial run kept for diagnosis: $backup" >&2
	elif [[ $status != 0 && $phase == snapshot ]]; then
		echo "Nothing was changed; could not tidy partial run $backup" >&2
	fi
	[[ $phase == pending ]] || exit "$status"
	echo "Installation failed; restoring from $backup" >&2
	restore_files "$backup" || failed=true
	restore_profiles "$backup" || failed=true
	cp -a -- "$backup/boot/." "$BOOT_DIR/" || failed=true
	restore_cursor "$backup" || failed=true
	udevadm control --reload || failed=true
	systemctl daemon-reload || failed=true
	nmcli general reload conf || failed=true
	if $failed; then
		echo "RECOVERY INCOMPLETE: do not reboot; retry: $0 --recover $backup" >&2
	else
		rm -f -- "$backup/pending"
		echo "Previous config, profiles and boot files restored; backup: $backup" >&2
	fi
	exit 1
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ ${1:-} == --recover ]]; then
	[[ $# == 2 ]] || die "usage: $0 --recover BACKUP_DIRECTORY"
	backup=$(readlink -f "$2")
	[[ $backup == "$STATE_ROOT"/run.* && -f $backup/before/3 && -d $backup/boot && -f $backup/profiles && -f $backup/parent && -f $backup/pending && ! -f $backup/complete ]] || die "not an incomplete recovery backup"
	phase=pending
	restore_files "$backup"
	restore_profiles "$backup"
	cp -a -- "$backup/boot/." "$BOOT_DIR/"
	restore_cursor "$backup"
	udevadm control --reload
	systemctl daemon-reload
	nmcli general reload conf
	phase=none
	rm -f -- "$backup/pending"
	echo "Recovered $backup. Reboot before relying on device policy."
	exit 0
fi

for previous in "$STATE_ROOT"/run.*/pending; do
	[[ ! -f $previous || -f ${previous%/pending}/complete ]] ||
		die "unfinished recovery; run: $0 --recover ${previous%/pending}"
done

if [[ ${1:-} == --undo ]]; then
	[[ $# == 2 ]] || die "usage: $0 --undo BACKUP_DIRECTORY"
	backup=$(readlink -f "$2")
	[[ $backup == "$STATE_ROOT"/run.* && -f $backup/complete && ! -e $backup/undone ]] || die "not a completed, unconsumed backup"
	[[ $(readlink -f "$STATE_ROOT/current") == "$backup" ]] || die "undo the most recent run first"
	for i in "${MANAGED[@]}"; do
		[[ ! -f $backup/after/$i ]] || cmp -s "${FILES[i]}" "$backup/after/$i" ||
			die "${FILES[i]} changed; reconcile it before undo"
		[[ -f $backup/after/$i || ! -e ${FILES[i]} ]] ||
			die "${FILES[i]} was not installed by this run; reconcile it before undo"
	done
	while read -r uuid value; do
		require_disabled "$uuid" "Wi-Fi profile $uuid changed; reconcile it before undo"
	done <"$backup/profiles"
	python3 "$HELPER" undo-grub "$GRUB_FILE" "$backup/before/3" >"$backup/undo-grub"
	source_backup=$backup
else
	[[ $# == 0 ]] || die "usage: $0 [--undo|--recover BACKUP_DIRECTORY]"
fi
backup=$(mktemp -d "$STATE_ROOT/run.XXXXXX")
phase=snapshot
: >"$backup/parent"
[[ ! -L $STATE_ROOT/current ]] || readlink -f "$STATE_ROOT/current" >"$backup/parent"
mkdir "$backup/before" "$backup/after"
for i in "${!FILES[@]}"; do
	file=${FILES[i]}
	[[ -d $(dirname "$file") ]] || ((i > 3)) || die "missing configuration directory for $file"
	[[ ! -L $file && (! -e $file || -f $file) ]] || die "refusing non-regular configuration: $file"
	[[ ! -f $file ]] || cp -a -- "$file" "$backup/before/$i"
done
[[ -f $backup/before/3 && -f $BOOT_DIR/grub/grub.cfg ]] || die "GRUB defaults or generated config missing"
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
cp --attributes-only "${KEEP_ATTRS[@]}" -- "$GRUB_FILE" "$backup/new-grub"
bash -n "$backup/new-grub"
[[ -z ${source_backup:-} ]] || printf '%s\n' "$source_backup" >"$backup/undo-source"
touch "$backup/pending"
phase=pending
if [[ -n ${source_backup:-} ]]; then
	for i in "${MANAGED[@]}"; do
		restore_one "$source_backup/before/$i" "${FILES[i]}"
	done
	restore_profiles "$source_backup"
else
	(umask 022 && for i in 4 5 6 7; do mkdir -p -- "$(dirname "${FILES[i]}")" || exit; done)
	cat >"$backup/after/0" <<'EOF'
# Installed by disable-device-power-saving.sh
ACTION=="add|bind", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add|bind", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="on"
EOF
	cat >"$backup/after/1" <<'EOF'
# Installed by disable-device-power-saving.sh
options snd_hda_intel power_save=0 power_save_controller=N
options nvidia NVreg_DynamicPowerManagement=0x00
options mt7921e disable_aspm=Y
EOF
	cat >"$backup/after/2" <<'EOF'
# Installed by disable-device-power-saving.sh
[connection]
wifi.powersave=2
EOF
	cat >"$backup/after/4" <<'EOF'
# Installed by disable-device-power-saving.sh
[Unit]
Description=Late device power policy pass (disable-device-power-saving.sh)
# After=suspend.target plus the suspend.target drop-in re-runs it on resume.
After=systemd-udev-trigger.service sound.target suspend.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/device-power-late
EOF
	cat >"$backup/after/5" <<'EOF'
# Installed by disable-device-power-saving.sh
[Unit]
Wants=device-power-late.service
EOF
	cp -- "$backup/after/5" "$backup/after/7"
	cat >"$backup/after/6" <<'EOF'
#!/usr/bin/env bash
# Installed by disable-device-power-saving.sh; run by device-power-late.service.
# Drivers such as snd_hda_intel re-enable runtime PM after the udev bind rule,
# and firmware that owns ASPM (ACPI FADT) keeps L0s/L1 on regardless of
# pcie_aspm.policy. This pass runs once udev has settled, and after resume.
set -u
status=0
force_on() {
	local ctl
	for ctl in /sys/bus/usb/devices/*/power/control /sys/bus/pci/devices/*/power/control; do
		[[ -e $ctl && $(<"$ctl") != on ]] || continue
		if echo on >"$ctl"; then
			echo "$1: runtime PM forced off for ${ctl%/power/control}"
		else
			echo "warning: cannot write $ctl" >&2
		fi
	done
}
udevadm settle --timeout=30 || echo "udev queue not settled; continuing" >&2
force_on pass
# Drivers that finish probing asynchronously can re-enable runtime PM after
# the first pass; the recheck catches and logs them.
sleep 3
force_on recheck
# Clear Link Control ASPM bits 0-1, deepest functions first, so each endpoint
# is disabled before its upstream bridge.
mapfile -t devices < <(
	for dev in /sys/bus/pci/devices/*; do
		[[ -e $dev ]] || continue
		path=$(readlink -f "$dev")
		slashes=${path//[!\/]/}
		printf '%d %s\n' "${#slashes}" "${dev##*/}"
	done | sort -k1,1nr -k2,2 | cut -d' ' -f2
)
for dev in "${devices[@]}"; do
	lnkctl=$(setpci -s "$dev" CAP_EXP+10.w 2>/dev/null) || continue
	# ffff means the device isn't answering; a masked write would set Link Disable.
	[[ $lnkctl =~ ^[0-9a-fA-F]{4}$ && ${lnkctl,,} != ffff ]] || continue
	((0x$lnkctl & 3)) || continue
	if setpci -s "$dev" CAP_EXP+10.w=0:3; then
		echo "ASPM disabled on $dev (Link Control was $lnkctl)"
	else
		status=1
	fi
done
exit "$status"
EOF
	chmod 644 "$backup"/after/{0,1,2,4,5,7}
	for i in "${MANAGED[@]}"; do
		[[ ! -f $backup/before/$i ]] ||
			cp --attributes-only "${KEEP_ATTRS[@]}" -- "$backup/before/$i" "$backup/after/$i"
		[[ $i != 6 ]] || chmod 755 "$backup/after/6"
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
mkinitcpio -P
grub-mkconfig -o "$BOOT_DIR/grub/grub.cfg"
[[ -n ${source_backup:-} ]] || python3 "$HELPER" boot <"$BOOT_DIR/grub/grub.cfg"
udevadm control --reload
systemctl daemon-reload
nmcli general reload conf
if [[ -n ${source_backup:-} ]]; then
	touch "$source_backup/undone"
	current=$(cat "$source_backup/parent")
else
	cp -a -- "$GRUB_FILE" "$backup/after/3"
	touch "$backup/complete"
	current=$backup
fi
if [[ -n $current && -d $current ]]; then
	ln -sfnT "$current" "$STATE_ROOT/current"
else
	rm -f "$STATE_ROOT/current"
fi
phase=none
rm -f -- "$backup/pending"
# Only once pending is gone, so --recover never restores a half-deleted /boot copy (SYS-7).
[[ $backup != "$STATE_ROOT"/run.?* ]] || rm -rf -- "${backup:?}/boot" ||
	echo "warning: could not remove $backup/boot; it is no longer needed" >&2

if [[ -n ${source_backup:-} ]]; then
	systemctl reset-failed device-power-late.service 2>/dev/null || true
	echo "Undo complete. Reboot to restore device policy, including loaded udev/sysfs and Wi-Fi state."
	exit 0
fi
echo -1 >/sys/module/usbcore/parameters/autosuspend || true
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
systemctl start device-power-late.service || echo "Late pass failed; see: journalctl -u device-power-late" >&2
echo "Done. Reboot for full device policy. Undo: $0 --undo $backup"
