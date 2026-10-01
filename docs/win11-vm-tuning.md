# Windows 11 VM Tuning (Physical SATA SSD, Virtio Input) — 2026-09-25

The `win11` VM on `dell-optiplex` (`qemu:///system`, `pc-q35-10.0`, UEFI) boots from a whole physical SATA SSD passed through as a raw block device, a SanDisk `SD7TB3Q-256G-1006` that shows up as `sdb` on the host. On 2026-09-25 its disk definition was tuned so the guest sees the drive as the SSD it really is, and virtio mouse and keyboard devices were added. Host versions at the time: libvirt 11.3.0 and QEMU 10.0.13 (Debian 13 trixie). Host-wide KVM setup lives in [kvm-virtualization-setup.md](kvm-virtualization-setup.md).

Both changes were applied and accepted by `virsh define`, but the guest had not yet been booted to verify them from the Windows side when this was written.

## Read the drive's real properties first

Everything in the disk XML below comes from the host, not from guesses. For a different drive, rerun these and substitute the values:

```bash
ls -l /dev/disk/by-id/ | grep -v part          # stable path for <source dev=...>
lsblk -d -o NAME,MODEL,SERIAL,ROTA,DISC-GRAN,WWN
cat /sys/block/sdX/queue/logical_block_size /sys/block/sdX/queue/physical_block_size
```

For this SanDisk the results were: `ROTA 0` (SSD), serial `155323404180`, 512-byte logical and 4096-byte physical sectors, 4K discard granularity, WWN `0x5001b44f35940b94`.

## Disk definition

```xml
<disk type="block" device="disk">
  <driver name="qemu" type="raw" cache="none" io="native" discard="unmap" detect_zeroes="unmap"/>
  <source dev="/dev/disk/by-id/ata-SanDisk_SD7TB3Q-256G-1006_155323404180"/>
  <target dev="sda" bus="sata" rotation_rate="1"/>
  <blockio logical_block_size="512" physical_block_size="4096"/>
  <serial>155323404180</serial>
  <boot order="1"/>
  <address type="drive" controller="0" bus="0" target="0" unit="0"/>
</disk>
```

`rotation_rate="1"` is the change that matters most: it reports the disk as non-rotational, so Windows' Optimize Drives sends TRIM instead of defragmenting. `discard="unmap"` passes those TRIMs through to the real SSD, and `detect_zeroes="unmap"` turns guest writes of all-zero blocks into discards as well. `<blockio>` matches the drive's real sector sizes so the guest aligns its I/O to 4K. `<serial>` passes the real serial through instead of a QEMU-generated one, so Windows sees the same disk identity whether it runs in the VM or on bare metal. `cache="none" io="native"` was already in place and is the usual choice for a raw block device.

**Do not add `discard_granularity` on a SATA disk.** The first attempt set `discard_granularity="4096"` on `<blockio>`. libvirt accepted it, but the VM refused to start because QEMU's SATA emulation (`ide-hd`) only accepts 512:

```text
qemu-system-x86_64: -device {"driver":"ide-hd",...,"discard_granularity":4096,...}: discard_granularity must be 512 for ide
```

Leaving the attribute out fixed it, and TRIM still works: the host block layer splits and aligns the 512-byte discards to the SSD's own granularity.

The SATA bus also has two limits. The guest still sees the model as "QEMU HARDDISK", because libvirt's `<vendor>`/`<product>` only apply to SCSI disks. The real WWN can't be passed through either, since libvirt only accepts `<wwn>` on the IDE and SCSI buses. If either one ever matters, the disk would have to move to a `virtio-scsi` controller (`bus="scsi"`). Windows then needs the `vioscsi` driver installed *before* the switch, or it won't boot.

## Virtio mouse and keyboard

These two lines were added next to the existing PS/2 input entries:

```xml
<input type="mouse" bus="virtio"/>
<input type="keyboard" bus="virtio"/>
```

libvirt assigns PCI addresses to them on define. The PS/2 pair stays: on `pc-q35`, libvirt adds it back on every define anyway, and it handles input in the UEFI firmware and until Windows' virtio driver loads. The reasoning is covered in detail in [kvm-virtualization-setup.md](kvm-virtualization-setup.md). Unlike the helper script described there, no USB tablet was added here.

Windows has no built-in virtio input driver. Mount the [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts) ISO, then run its guest-tools installer or install `vioinput` from Device Manager. Until then, the devices show up as unknown PCI devices and input keeps working through PS/2.

## Applying the changes

The VM must be shut off. Edit the inactive definition and redefine it, keeping a backup of the previous XML:

```bash
virsh -c qemu:///system dumpxml --inactive --security-info win11 > win11.bak.xml
cp win11.bak.xml win11.xml
# edit win11.xml
virsh -c qemu:///system define win11.xml
virsh -c qemu:///system dumpxml --inactive win11 | grep -E "blockio|rotation_rate|<serial|<input"
```

`virsh dumpxml` writes attributes with single quotes, so a `sed` edit has to match `attr='value'`, not `attr="value"`. A double-quoted pattern silently matches nothing and redefines the domain unchanged. `virsh edit win11` avoids that and validates the XML on save.

## Verifying inside Windows

In an elevated PowerShell:

```powershell
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, SerialNumber   # expect SSD and 155323404180
Optimize-Volume -DriveLetter C -ReTrim -Verbose                          # expect a retrim, not a defrag
```

After `vioinput` is installed, Device Manager should list the virtio devices under "Keyboards" and "Mice and other pointing devices".
