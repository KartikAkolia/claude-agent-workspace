# KVM/QEMU/Libvirt Virtualization (Homelab Host) — 2026-08-25

Kartik set up KVM/QEMU/libvirt virtualization on the homelab host (`dell-optiplex`, 192.168.0.222), following [christitus.com/vm-setup-in-linux](https://christitus.com/vm-setup-in-linux/), then added bridge networking per [thelinuxbook.com/chapter4.2-networking](https://thelinuxbook.com/chapter4.2-networking), and later converted an existing VM's input devices to virtio plus a reusable helper script for that conversion.

## What was installed

Confirmed via `dpkg -l` on the host: `qemu-system-x86` (11.0.3+ds-2) and the rest of the `qemu-system-*`/`qemu-utils`/`qemu-block-extra` set, `libvirt-daemon-system` (12.6.0-1, pulls in the full driver/storage/network/nwfilter/lock driver set), `virt-manager` (5.1.0-2), `ovmf`/`ovmf-generic`/`ovmf-amdsev`/`ovmf-inteltdx` (2026.05-2), and `ethtool` (7.1-1, needed for the later bridge networking step).

`kartik` is a member of the `libvirt` group (`groups kartik` confirms: `... netdev libvirt`). Combined with the default polkit rule at `/usr/share/polkit-1/rules.d/60-libvirt.rules`:

```js
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("libvirt")) {
        return polkit.Result.YES;
    }
});
```

this gives `kartik` passwordless, non-root management of `qemu:///system` — verified end-to-end (not just inferred) by running real `virsh` commands as `kartik` against `qemu:///system` without `sudo`.

`/etc/libvirt/qemu.conf` and `/etc/libvirt/libvirtd.conf` are both untouched at Debian's shipped defaults — no edits were needed. The relevant ownership lines are present but commented out, meaning the compiled-in defaults apply: `#user = "libvirt-qemu"`, `#group = "libvirt-qemu"`, `#dynamic_ownership = 1`.

### `qemu:///system` vs `qemu:///session` — the one real gotcha

Plain `virsh` (or `virt-manager`) run as a non-root user without `-c qemu:///system` silently defaults to `qemu:///session` — a separate, unprivileged, per-user libvirt scope with its own storage pools and networks, invisible to the system-wide `default` network and to anything started as root. This bit us once directly (see the `br0net` section below): a `virsh net-define` run without `-c qemu:///system` landed the network in the wrong scope and spun up a stray unprivileged `libvirtd` process. Always pass `-c qemu:///system` explicitly (or use virt-manager's "QEMU/KVM" connection, not "QEMU/KVM user session") for anything meant to be host-wide.

## OVMF firmware selection (UEFI, non-Secure-Boot guests)

When creating a VM with UEFI selected, virt-manager lists multiple OVMF firmware options sourced from the JSON descriptors under `/usr/share/qemu/firmware/`. Confirmed on this host:

| File | Secure Boot |
|---|---|
| `40-edk2-x86_64-secure-enrolled.json` | Enabled, pre-enrolled keys |
| `50-edk2-x86_64-secure.json` | Capable, but off by default |
| `60-edk2-x86_64.json` | **Not capable — no Secure Boot at all** |
| `60-edk2-x86_64-amdsev.json` / `60-edk2-x86_64-inteltdx.json` | Confidential-computing variants (AMD SEV / Intel TDX), not relevant to a normal desktop guest |

`60-edk2-x86_64.json`'s own description confirms it directly: *"UEFI firmware for x86_64, without Secure Boot, optional SMM, empty varstore"*, pointing at `/usr/share/OVMF/OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd`.

**For a non-Secure-Boot guest (e.g. Arch Linux, which doesn't ship signed boot binaries by default), pick the firmware entry that does *not* mention Secure Boot in virt-manager's picker** — this maps to `60-edk2-x86_64.json`. Picking one of the Secure-Boot-capable entries and leaving Secure Boot enabled is what caused the original Arch Linux VM to fail to boot until this was corrected.

## Bridge networking (`br0`)

Reference: [thelinuxbook.com/chapter4.2-networking](https://thelinuxbook.com/chapter4.2-networking). Built on the NetworkManager setup already in place from `docs/homelab-networkmanager-plan.md` (static IP, `enp3s0` NM-managed).

Confirmed current NetworkManager connections (`nmcli -t -f NAME,TYPE,DEVICE,AUTOCONNECT con show`):

| Connection | Type | Device | Autoconnect |
|---|---|---|---|
| `br0` | bridge | `br0` | yes |
| `br0-port1` | ethernet | `enp3s0` | yes (slaved to `br0`) |
| `enp3s0-rollback` | ethernet | (none) | **no** — kept as a manual fallback, not deleted |
| `virbr0` | bridge | `virbr0` | yes — libvirt's own default NAT bridge, unrelated |

`br0` carries the host's actual identity: static `192.168.0.222/24`, gateway `192.168.0.1`, DNS `194.168.4.100`/`194.168.8.100`, IPv6 disabled, `bridge.stp no` (avoids the STP forwarding-delay blackout on a single-uplink bridge with no loop risk). `enp3s0` itself is now just a bridge port (`br0-port1`) with no IP of its own.

The rollback profile (`enp3s0-rollback`, `autoconnect no`) was deliberately kept rather than deleted, in case `br0` ever needs to be torn down and `enp3s0` given back a direct IP.

**Cutover safety**: this was done live over the same SSH session that depends on the interface being reconfigured, so it followed `homelab-admin`'s rule against changing networking without rollback/out-of-band access — Kartik confirmed physical console access as a fallback before the cutover ran. No SSH interruption occurred; verified after with the routing table, `bridge link show`, and a gateway ping.

## Libvirt bridge network (`br0net`)

A second libvirt network, `br0net`, was defined on top of `br0` so VMs can get a bridged (LAN-visible) NIC instead of libvirt's default NATted `virbr0`:

```xml
<network>
  <name>br0net</name>
  <forward mode='bridge'/>
  <bridge name='br0'/>
</network>
```

Confirmed active, autostart, and persistent under `qemu:///system` alongside `default`:

```
 Name      State    Autostart   Persistent
--------------------------------------------
 br0net    active   yes         yes
 default   active   yes         yes
```

**Self-caught mistake during setup**: the first `virsh net-define`/`net-start`/`net-autostart` run was made without `-c qemu:///system`, which — per the gotcha above — silently defined `br0net` under `qemu:///session` instead, invisible to virt-manager and spinning up a stray unprivileged `libvirtd` process. Caught by comparing `net-list --all` output between the two scopes, fixed by destroying/undefining it from `qemu:///session` and redefining correctly under `qemu:///system`.

To attach a VM to this network instead of NAT, select `br0net` as the network source for its NIC in virt-manager (or `<source network='br0net'/>` in the domain XML).

## VM input devices: PS/2 → virtio, plus a USB tablet

For the `archlinux` VM specifically, and now for any VM via the helper script below, mouse and keyboard input devices were changed from the QEMU-emulated PS/2 bus to virtio (paravirtualized, lower latency), and a USB tablet device was added for absolute-position pointer mapping (so the cursor doesn't need to "catch up" to the host pointer in a SPICE/VNC viewer, unlike a relative-motion mouse).

**Important non-bug to know about**: libvirt/QEMU's `pc-q35` machine type always exposes an implicit PS/2 keyboard+mouse pair from the emulated chipset's i8042 controller — libvirt re-adds an explicit `<input type='mouse' bus='ps2'/>` / `<input type='keyboard' bus='ps2'/>` pair to the domain XML on every `virsh define`, even when virtio input devices are also explicitly present. **This is expected, not a defect**, and isn't something to "clean up" — the PS/2 pair is what handles keyboard input at the firmware/GRUB level before the guest OS's virtio-input driver has loaded, so removing it would break early-boot keyboard interaction. A correctly-converted `pc-q35` VM ends up with 5 input devices total: virtio mouse, virtio keyboard, PS/2 mouse, PS/2 keyboard, USB tablet — not 2.

Editing pattern used (offline, VM must be `shut off`):

```bash
virsh -c qemu:///system dumpxml --inactive <vm> > /tmp/<vm>.xml
# edit /tmp/<vm>.xml
virsh -c qemu:///system define /tmp/<vm>.xml
virsh -c qemu:///system dumpxml <vm> > /dev/null   # validates the result
```

### Helper script: `vm-set-virtio-input.sh`

Deployed at `/home/kartik/bin/vm-set-virtio-input.sh` on the host (not committed to this repo — operational scripts live on-host; this repo's `docs/` holds planning/reference notes, mirroring the existing pattern for e.g. the Minecraft backup script).

```
vm-set-virtio-input.sh <vm-name> [<vm-name> ...]   # process one or more VMs by name
vm-set-virtio-input.sh                             # prompt interactively, one VM per line, blank line to stop
```

For each named VM: confirms it exists and is `shut off`, dumps the inactive XML, converts any PS/2 mouse/keyboard entries to virtio (or adds fresh virtio entries if the VM had no explicit input devices at all), adds a USB tablet if one isn't already present, and redefines the domain. **Idempotent** — rerunning against an already-converted VM reports "no changes needed" and makes no edits.

The first draft had a real bug, caught during testing before being handed off: it converted *any* `bus='ps2'` line to virtio unconditionally, including the harmless implicit PS/2 pair described above — which duplicated the virtio devices on a VM that already had them (4 input devices where the intent was 2, before the PS/2 pair libvirt adds back on top). Fixed by only converting a PS/2 line when no virtio device of that type already exists; a PS/2 pair coexisting with virtio devices is left alone on every run. Verified via: (1) rerunning against the already-converted `archlinux` VM — correctly reports "no changes needed"; (2) a disposable throwaway domain with zero explicit input devices, defined, run through the script, confirmed to land at exactly 5 input devices (1 each), then undefined and cleaned up.

**Windows/Git Bash note**: `plink`/`pscp` calls that pass absolute Unix paths (e.g. `/home/kartik/bin/...`) as command arguments need `MSYS_NO_PATHCONV=1` prefixed on the command, otherwise Git Bash's MSYS path translation mangles them into a Windows path (e.g. `C:/Program Files/...`) before they reach the remote shell.

## Shell linting tools installed on the host

`shellcheck` (0.11.0), `checkbashisms` (from the `devscripts` package, 2.26.11), and `dash` (as a real POSIX-sh test target) were installed via `apt-get install shellcheck devscripts dash`, specifically to check `vm-set-virtio-input.sh` for logic errors and unintended bashisms before trusting it for repeated use. Both `vm-set-virtio-input.sh` and `/opt/minecraft/backup.sh` (see `docs/minecraft-server-setup.md`) were linted with these tools; the backup script's one finding (an unquoted `$TS` in `SC2086`) was fixed. These tools are now available on the host for linting any future shell script — no need to reinstall.

## Sources

- [ChrisTitusTech — VM Setup in Linux](https://christitus.com/vm-setup-in-linux/)
- [The Linux Book — Chapter 4.2, Networking](https://thelinuxbook.com/chapter4.2-networking)
- [libvirt — Firmware descriptor JSON format](https://libvirt.org/kbase/firmware.html)
- [ShellCheck](https://www.shellcheck.net/) / [Debian devscripts — checkbashisms](https://manpages.debian.org/devscripts/checkbashisms.1.en.html)
