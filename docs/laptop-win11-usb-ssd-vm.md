# Laptop Windows 11 VM on a USB-attached NVMe SSD — 2026-11-21

The `win11` VM on the CachyOS laptop (`asus-vivobook`, `qemu:///system`, `pc-q35-11.1`, UEFI/OVMF, 4 vCPUs, 8 GiB) boots from a whole physical disk: a WD PC SN730 512 GB NVMe in a Sabrent USB enclosure (Realtek RTL9210, USB ID `0bda:9210`). The host sees it as a USB SCSI disk, `sda`. Host versions at the time: libvirt 12.9.0 and QEMU 11.1.3. The GPU passthrough history for this VM is in [laptop-vfio-passthrough.md](laptop-vfio-passthrough.md); the Optiplex's separate `win11` on a SATA SSD is in [win11-vm-tuning.md](win11-vm-tuning.md).

## Disk path

Use the drive's own by-id link, not the enclosure's. The `ata-` name comes from the SN730's model and serial, so it survives a move to another enclosure or port. The `usb-Sabrent_SSD_830700000022-0:0` link names the enclosure and would point at whatever drive is inside it.

```text
/dev/disk/by-id/ata-WDC_PC_SN730_SDBQNTY-512G-1001_202694800158
```

Real NVMe passthrough isn't possible here: the drive sits behind a USB bridge, so there's no PCIe NVMe controller to hand to the guest.

## Current disk and device definitions

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
  <source dev='/dev/disk/by-id/ata-WDC_PC_SN730_SDBQNTY-512G-1001_202694800158'/>
  <target dev='vda' bus='virtio'/>
</disk>

<interface type='bridge'>
  <source bridge='br0'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4'/>
</interface>

<input type='mouse' bus='virtio'/>
<input type='keyboard' bus='virtio'/>
```

The PS/2 mouse and keyboard and the USB tablet stay alongside the virtio input devices. The tablet gives absolute pointer positioning in the SPICE viewer. `queues='4'` matches the vCPU count, and the host's `vhost_net` module is loaded. Windows needs the virtio-win drivers (`viostor`, `NetKVM`, `vioinput`) from the [virtio-win ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).

## Moving a Windows boot disk from SATA to virtio

Installing virtio-win copies `viostor` into the driver store but doesn't create its service until Windows sees a virtio disk. Switching the boot disk to virtio before that fails with `INACCESSIBLE_BOOT_DEVICE`. Device Manager won't show "Red Hat VirtIO SCSI controller" while the disk is on SATA, so that's no test; `sc qc viostor` is. If it reports `OpenService FAILED 1060`, the service doesn't exist yet.

What worked on 2026-11-21:

1. Boot on SATA and run `bcdedit /set {current} safeboot minimal` as admin.
2. Hot-plug a throwaway virtio disk into the running VM (`virsh vol-create-as default viostor-temp.qcow2 1G --format qcow2`, then `virsh attach-device win11 <disk xml> --live`). Windows binds `viostor` to it.
3. `sc qc viostor` should now show `START_TYPE : 0 BOOT_START`.
4. Shut down fully (not Restart, which keeps the running SATA config), switch the disk to `bus='virtio'` with no `<address>`, and boot. It comes up in Safe Mode.
5. Run `bcdedit /deletevalue {current} safeboot` and reboot. Delete the temporary volume with `virsh vol-delete viostor-temp.qcow2 --pool default`.

## Things that don't work on this bus

- **`rotation_rate='1'` isn't valid on virtio.** libvirt only supports it on SCSI, IDE and SATA disks, so Task Manager keeps showing the virtio disk as "HDD (SCSI)". The label is cosmetic. Getting an SSD label would mean moving to a `virtio-scsi` controller, which needs the same driver dance for `vioscsi`.
- **Emulated NVMe (`bus='nvme'`, libvirt 11.5+) works but isn't worth it.** It needs a `<serial>` and adds an NVMe controller. QEMU's emulated NVMe is no faster than virtio, and USB is the bottleneck either way. It was tried on 2026-11-21 and reverted.

## TRIM through the USB enclosure

Windows had TRIM enabled (`fsutil behavior query DisableDeleteNotify` → `0` for NTFS and ReFS), but the host dropped it: `lsblk -D /dev/sda` showed `DISC-MAX 0B`, and `/sys/block/sda/device/scsi_disk/*/provisioning_mode` was `full`. The RTL9210 generally supports UNMAP, but Linux doesn't enable it for USB disks by default. Enabling it for the current session:

```bash
echo unmap | pkexec tee /sys/block/sda/device/scsi_disk/*/provisioning_mode
lsblk -D /dev/sda   # 2026-11-21: DISC-GRAN 512B, DISC-MAX 4G
```

That lasts until the enclosure is replugged or the host reboots. It still needs a real TRIM test: run Optimize on C: in Windows, then check `journalctl -k | grep -iE 'sda|uas|I/O error|reset'` on the host. If the log is clean, make it persistent with `/etc/udev/rules.d/50-rtl9210-unmap.rules`:

```text
ACTION=="add|change", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"
```

Then `pkexec udevadm control --reload` and replug. If the test produces I/O errors, write `full` back (or replug) and leave TRIM off. Both steps are tracked as open item 61 in [handoff.md](handoff.md).

## Guest loses network after the USB Ethernet drops

`br0`'s only uplink is the ASIX AX88179 USB Ethernet adapter (`enp100s0f3u3c3`, `0b95:1790`). On 2026-11-21 at 20:53 a USB reset dropped it. `br0`'s DHCP then timed out after the default 45 s, and NetworkManager failed the activation, detached every port, and re-created the bridge. It re-added only `enp100s0f3u3c3`, because NM doesn't own libvirt's tap. The host came back, but the running guest stayed on `169.254.x.x` with no internet. The symptom is `bridge link` listing no `vnet*` port.

Recovery without restarting the VM: re-attach the tap, then toggle the virtual link so Windows asks for a new DHCP lease right away.

```bash
pkexec ip link set vnet0 master br0
virsh -c qemu:///system domif-setlink win11 vnet0 down
virsh -c qemu:///system domif-setlink win11 vnet0 up
virsh -c qemu:///system qemu-agent-command win11 '{"execute":"guest-network-get-interfaces"}'
```

`virsh domiflist win11` gives the tap name if it isn't `vnet0`. To prevent this, the `br0` profile now waits for DHCP forever, so a lost uplink no longer fails the activation and strips the bridge's ports: `nmcli con modify br0 ipv4.dhcp-timeout 2147483647`, set 2026-11-21. It takes effect from `br0`'s next activation. It hasn't been tested against a real Ethernet drop yet.
