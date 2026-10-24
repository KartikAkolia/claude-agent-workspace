#!/usr/bin/env bash
# disable-device-power-saving.sh — keep every USB and PCI device on
# asus-vivobook (Arch, GRUB, mkinitcpio) fully powered: no USB autosuspend,
# no PCI runtime PM, no NVIDIA dGPU runtime suspend, no PCIe ASPM power
# saving, no NVMe APST, no HDA audio power_save, no Wi-Fi powersave.
# System suspend/hibernate/lid handling is deliberately left untouched.
#
# Installs, all via sudo (so run it in a real terminal):
#   /etc/udev/rules.d/99-no-runtime-pm.rules        power/control=on for usb+pci
#   /etc/modprobe.d/no-power-saving.conf            hda, nvidia, iwlmvm options
#   /etc/NetworkManager/conf.d/wifi-powersave-off.conf
#   /etc/default/grub                               cmdline params (backup kept
#                                                   as /etc/default/grub.bak-nopm)
# then regenerates grub.cfg and the initramfs (the kms hook pulls nvidia into
# it, and the modconf hook bakes in the modprobe.d options), and applies what
# it can to the running system. The NVIDIA, NVMe and ASPM changes need a
# reboot to fully land.
#
# Kernel params go on the cmdline rather than in modprobe.d because usbcore is
# built into this kernel (modprobe.d options never reach it) and pcie_aspm is
# not a module at all.
#
#   scripts/disable-device-power-saving.sh
# Rerun-safe. To undo: `sudo rm` the three new files, restore the grub backup,
# then `sudo grub-mkconfig -o /boot/grub/grub.cfg && sudo mkinitcpio -P`.

set -euo pipefail

readonly RULE_FILE=/etc/udev/rules.d/99-no-runtime-pm.rules
readonly MODPROBE_FILE=/etc/modprobe.d/no-power-saving.conf
readonly NM_FILE=/etc/NetworkManager/conf.d/wifi-powersave-off.conf
readonly GRUB_FILE=/etc/default/grub
readonly CMDLINE_PARAMS=(usbcore.autosuspend=-1 pcie_aspm.policy=performance nvme_core.default_ps_max_latency_us=0)

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

command -v grub-mkconfig >/dev/null || die "grub-mkconfig not found"
command -v mkinitcpio >/dev/null || die "mkinitcpio not found"
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' "$GRUB_FILE" || die "no GRUB_CMDLINE_LINUX_DEFAULT in $GRUB_FILE"

# Named 99- so it runs after 60-autosuspend.rules, which sets "auto" for
# devices hwdb marks ID_AUTOSUSPEND=1. "bind" catches drivers that re-enable
# runtime PM when they attach.
rule='# Installed by scripts/disable-device-power-saving.sh — keep USB and PCI
# devices out of runtime suspend.
ACTION=="add|bind", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add|bind", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="on"'

# NVreg_DynamicPowerManagement=0x00 turns off the dGPU's RTD3 runtime suspend
# (the driver defaults to 3 = fine-grained on this laptop). iwlmvm
# power_scheme=1 is "active" (no power saving).
modprobe_conf='# Installed by scripts/disable-device-power-saving.sh
options snd_hda_intel power_save=0 power_save_controller=N
options nvidia NVreg_DynamicPowerManagement=0x00
options iwlmvm power_scheme=1'

# wifi.powersave: 2 = disable.
nm_conf='# Installed by scripts/disable-device-power-saving.sh
[connection]
wifi.powersave = 2'

printf 'Installing %s, %s and %s.\n' "$RULE_FILE" "$MODPROBE_FILE" "$NM_FILE"
printf '%s\n' "$rule" | sudo tee "$RULE_FILE" >/dev/null
printf '%s\n' "$modprobe_conf" | sudo tee "$MODPROBE_FILE" >/dev/null
printf '%s\n' "$nm_conf" | sudo tee "$NM_FILE" >/dev/null

[ -f "$GRUB_FILE.bak-nopm" ] || sudo cp -p "$GRUB_FILE" "$GRUB_FILE.bak-nopm"
for param in "${CMDLINE_PARAMS[@]}"; do
	key="${param%%=*}"
	if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=\".*\b${key//./\\.}=" "$GRUB_FILE"; then
		sudo sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\b${key//./\\.}=[^ \"]*/$param/" "$GRUB_FILE"
	else
		sudo sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $param\"/" "$GRUB_FILE"
	fi
done
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"
# The append above only matches a line ending in the closing quote; fail
# rather than build a grub.cfg that silently lacks a parameter.
for param in "${CMDLINE_PARAMS[@]}"; do
	grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=\".*\b${param//./\\.}\b" "$GRUB_FILE" ||
		die "$param did not land in $GRUB_FILE; add it by hand and rerun"
done

sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo mkinitcpio -P

# Apply to the running system. Failures here are non-fatal: whatever doesn't
# take now takes on the next boot.
echo "Applying to the running system..."
sudo udevadm control --reload
echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null || true
for ctl in /sys/bus/usb/devices/*/power/control /sys/bus/pci/devices/*/power/control; do
	echo on | sudo tee "$ctl" >/dev/null 2>&1 || true
done
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy >/dev/null 2>&1 ||
	echo "  ASPM policy not writable now (firmware-controlled or needs reboot)"
if [ -e /sys/module/snd_hda_intel/parameters/power_save ]; then
	echo 0 | sudo tee /sys/module/snd_hda_intel/parameters/power_save >/dev/null || true
	echo N | sudo tee /sys/module/snd_hda_intel/parameters/power_save_controller >/dev/null || true
fi
for dev in /sys/class/net/*/wireless; do
	[ -e "$dev" ] || continue
	iface="${dev%/wireless}"
	iface="${iface##*/}"
	if command -v iw >/dev/null; then
		sudo iw dev "$iface" set power_save off || true
	else
		echo "  iw not installed; $iface powersave goes off after NetworkManager reconnects"
	fi
done
sudo systemctl reload NetworkManager || true

echo "Done. Reboot to apply the NVIDIA, NVMe APST and ASPM changes."
