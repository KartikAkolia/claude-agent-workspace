# Laptop VFIO GPU Passthrough — NVIDIA RTX 4060 → Windows VM

Status: **REVERTED to native host GPU use 2026-09-07 — see "Revert to native NVIDIA driver" section near the end. `win11`/Looking Glass/KVMFR are dormant, not deleted; the GPU currently runs `nvidia` for host-side use (PRIME render offload confirmed working) and the VM cannot start until the revert steps below are undone. Everything below this line describes the passthrough build as it stood before the revert — kept intact as the re-enable runbook.**

Status (as of the 2026-08-28 passthrough build, before the 2026-09-07 revert): **Phase 1 (host isolation) done and verified after reboot 2026-08-28. Host Wi-Fi → NetworkManager migration done and verified after reboot 2026-08-28. Phase 3 (Windows 11 VM, `win11`) already built by Kartik outside this runbook's step-by-step, with GPU passthrough confirmed live via domain XML 2026-08-28 — see Phase 3 below for the actual config and where it deviates from the original plan. Phase 4 (Looking Glass) host-side chain fully built and verified live against the running VM 2026-08-28: client compiled + installed, KVMFR module loaded and persistent, IVSHMEM device attached and confirmed in the running QEMU process. Windows-side IDD install is the immediate next step. Phase 2 (vBIOS dump) status not verified this session — apparently not needed since passthrough already works without it.**

Kartik is setting up VFIO passthrough on his ASUS Vivobook (`asus-vivobook`) to hand the discrete NVIDIA GPU to a Windows VM for general Windows use, driven headless via an HDMI dummy plug + Looking Glass. The AMD iGPU (Radeon 780M) stays as the host GPU. Following the HikariKnight [`quickpassthrough`](https://github.com/HikariKnight/quickpassthrough) tool and the [`vfio-setup-docs` wiki](https://github.com/HikariKnight/vfio-setup-docs/wiki).

Project state is also tracked in Claude Code memory (`vfio-4060-passthrough.md`); this file is the copy-pasteable execution runbook.

## Machine facts

Hardware facts from the initial discovery session (2026-08-28, recorded in memory — not re-verified line-by-line here):

| Fact | Value |
|---|---|
| Model | ASUS Vivobook Pro 15 OLED M6500XV |
| CPU | AMD Ryzen 9 7940HS, 8c/16t, single NUMA node |
| Host GPU (stays) | Radeon 780M iGPU, `64:00.0`, `amdgpu` |
| Passthrough target | NVIDIA RTX 4060 Max-Q/Mobile, `01:00.0` `[10de:28a0]` (VGA) + `01:00.1` `[10de:22be]` (HDMI audio) |
| IOMMU group | **13** — contains only those two functions; no ACS override / bridge passing needed |
| HDMI port wiring | Physically wired to the dGPU (`card0-HDMI-A-1` at `pci-0000:01:00.0`) — passthrough can drive a real display / dummy plug |
| vBIOS ROM node | `/sys/bus/pci/devices/0000:01:00.0/rom` exists and is dumpable (better than most laptops) |
| RAM | 14 GiB total (~12 usable), **0 swap** → Windows guest realistically 6–8 GB |
| OS | Debian forky/sid, kernel `7.1.8+deb14.1-amd64`, GRUB + UEFI, Secure Boot off, initramfs-tools |
| Virt stack | libvirt 12.6.0, QEMU 11.0.3, OVMF 4M (`/usr/share/OVMF/OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd`), swtpm 0.10.2 — all installed |

`kartik` is in `libvirt`/`kvm`/`video` groups. `/dev/kvm` present. **No passwordless sudo** on this box — Kartik runs every root step himself.

> Note: `docs/laptop-dual-boot-debian-setup.md` describes the same laptop with some conflicting facts (Secure Boot enabled, ~16 GB RAM, Intel AX210 Wi-Fi, Debian 12 bookworm). The running system checked this session is forky/sid with Secure Boot off and a `wlp2s0` Wi-Fi device on `a4:f9:33:cb:70:be`. Reconcile the two docs in a later pass — out of scope for the passthrough work.

## Phase 1 — Host isolation (DONE & VERIFIED 2026-08-28)

`quickpassthrough` 2.1.5 was run by Kartik (the TUI can't be driven by an agent). Recovery/backup dir: `~/vfio/` (`backup/` + `config/`).

Changes it made:

- **GRUB** — `GRUB_CMDLINE_LINUX_DEFAULT` now:
  `quiet iommu=pt amd_iommu=on vfio_pci.ids=10de:22be,10de:28a0 vfio_pci.disable_vga=1`
- **`/etc/modprobe.d/vfio.conf`** — softdep lines so `vfio_pci` loads before the GPU drivers:
  `softdep nvidia pre: vfio vfio_pci` (and the same for `nouveau`, `amdgpu`, `radeon`).
  `nouveau` is **not** blacklisted — it's the fallback if the bind race is ever lost. If that happens, add
  `blacklist nouveau` (the host doesn't need nouveau; it runs on `amdgpu`).
- **`/etc/initramfs-tools/modules`** — `vfio_pci`, `vfio`, `vfio_iommu_type1` added.

### Post-reboot verification (all passed 2026-08-28)

```sh
cat /proc/cmdline
# → carries: iommu=pt amd_iommu=on vfio_pci.ids=10de:22be,10de:28a0 vfio_pci.disable_vga=1

lspci -nnk -s 01:00.0     # VGA  → Kernel driver in use: vfio-pci   (Kernel modules: nouveau)
lspci -nnk -s 01:00.1     # Audio → Kernel driver in use: vfio-pci   (Kernel modules: snd_hda_intel)

# IOMMU group is clean — exactly the two functions:
for d in /sys/kernel/iommu_groups/*/devices/0000:01:00.*; do echo "$d"; done
# → both under iommu_groups/13
```

`dmesg | grep -iE 'vfio|AMD-Vi'` fails as a normal user (`kernel.dmesg_restrict`) — run `sudo dmesg | grep -iE 'AMD-Vi|iommu|vfio'` if you want to see IOMMU init lines. Not required; the driver binding already proves IOMMU + stubbing worked.

## VM networking — bridged over the USB Ethernet dongle (`br0`)

> **Resolved 2026-08-28:** `br0` is a real NetworkManager bridge — confirmed via `nmcli connection show br0` (uuid `883d4548-0d07-403c-a8af-7da45cb2ba7f`) — over `enx9c69d3002c84`, the USB-to-Ethernet dongle, with a slave connection `br0-slave-enx9c69d3002c84`. This is what the `win11` domain's `<interface type='bridge'><source bridge='br0'/>` actually rides on: Kartik built it directly at the console, outside this runbook, presumably to give the VM a real LAN-routable IP off the dongle since Wi-Fi can't be L2-bridged. The `default`-NAT-network plan below was the original assumption and is **not** what's running; kept for the still-valid stray-`virbr0` cleanup detail only.

**Boot-time side effect found and diagnosed 2026-08-28:** `br0` has `connection.autoconnect: yes` and `ipv4.method: auto` (DHCP), so it activates on every host boot regardless of whether `win11` is running. When nothing answers its DHCP request in time, NM waits out the full default `ipv4.dhcp-timeout` (45s) before giving up — this lines up almost exactly with a 46-second `NetworkManager-wait-online.service` boot stall (`sudo journalctl -u NetworkManager-wait-online.service -b`, `Starting...` → `Finished...` 46s apart). After the timeout, `br0` tears itself down — `ip -br addr show br0` returns "Device br0 does not exist" and `enx9c69d3002c84` drops to `disconnected` — so it's DHCP-timeout churn repeating every boot, not an ongoing fault.

**Fix — applied (verified 2026-08-28):** `br0`'s and its slave's autoconnect are now confirmed `no` (`nmcli -f NAME,AUTOCONNECT connection show` — was `yes` earlier the same session), and the `.nmconnection` keyfiles on disk carry a matching timestamp, so it no longer activates on boot at all:

```bash
sudo nmcli connection modify br0 connection.autoconnect no
sudo nmcli connection modify br0-slave-enx9c69d3002c84 connection.autoconnect no
# then, right before starting the VM:
sudo nmcli connection up br0
virsh -c qemu:///system start win11
```

Side note for anyone confused by `ip addr`/bare `nmcli` after this: `br0` is a *virtual* bridge, so its kernel interface only exists while the connection is active — with autoconnect off and nothing having brought it up, it won't appear in `ip addr`/`ip link`/`nmcli device status` at all (not "disconnected" the way a physical NIC like `enx9c69d3002c84` shows when idle). That's expected, not a sign the profile was deleted; the profile itself is still there (`nmcli connection show br0`, and the keyfile on disk).

**libvirt's `default` NAT network — disabled 2026-08-28**, since `br0` is the real (and only) VM networking path now and running an idle redundant NAT network alongside it serves no purpose:

```bash
virsh -c qemu:///system net-destroy default      # stop the running network
virsh -c qemu:///system net-autostart default --disable
```

Verified: `net-list --all` now shows `default` → `State: inactive`, `Autostart: no` (still `Persistent: yes`, so the definition is kept and it's a one-line `net-start`/`net-autostart default` to bring back if ever needed). Confirmed `win11`'s live XML doesn't reference it (`<interface type='bridge'><source bridge='br0'/>`), so nothing depended on it being up.

---

The section below documents the earlier (superseded) libvirt-`default`-NAT-network plan and its `virbr0` cleanup note, kept for reference — the network it describes is now the disabled one above, not something to build:

Checked 2026-08-28: `virsh -c qemu:///system net-list --all` shows the **`default` network active + autostart + persistent**, its `dnsmasq` (pid 1213) serving DHCP on `virbr0:67`, and 3 `masquerade` rules for `192.168.122.0/24` — libvirt's own NAT. The `virbr0` interface (MAC `52:54:00:3a:31:3e`, QEMU/libvirt OUI) is **owned by libvirt, not NetworkManager**.

This plan was dropped once `br0` was found to be what's actually wired into the VM's XML (see resolved note above). The `default`-network interface block below was never applied:

```xml
<interface type='network'>
  <source network='default'/>
  <model type='virtio'/>
</interface>
```

The guest gets a NAT'd `192.168.122.x` address (Wi-Fi can't be L2-bridged anyway). Fine for general Windows use; port-forward on the host for any inbound need.

**Cleanup:** there is a stray NetworkManager keyfile connection also named `virbr0` (`type=bridge`, autoconnect) — a conflicting shadow of libvirt's interface. It's why every `nmcli ... virbr0` attempt in a prior session activated then fell to `disconnected`. Delete it so it can't race libvirtd for the interface name on boot:

```bash
sudo nmcli connection delete virbr0
```

## Host Wi-Fi → NetworkManager (DONE & VERIFIED 2026-08-28)

Executed at the console 2026-08-28. Post-reboot check passed: `nmcli device status` shows `wlp2s0` → `connected` on connection `VM2411078` (auto-reconnected on boot, so autoconnect is effectively confirmed), `virbr0`/`lo` show `connected (externally)` (NM observing only, libvirt still owns `virbr0`), `ping 1.1.1.1` 0% loss ~14 ms, and `ps aux | grep [d]hcpcd` is empty — dhcpcd gone, ifupdown fully out of the path.

Open follow-ups:

- Confirm the stray NM `virbr0` keyfile profile is actually deleted, not just inert: `nmcli -t -f NAME,TYPE connection show | grep virbr0` should print nothing.
- DHCP reservation on MAC `a4:f9:33:cb:70:be` if a stable home address matters — NM's client-id differs from dhcpcd's so the lease may have changed from `192.168.0.13` (see below).

The runbook, current-state notes, rollback, and DHCP-reservation detail below are kept for reference / rollback.

**Not required for passthrough** — libvirt's NAT works whether ifupdown or NM owns `wlp2s0`. Kartik wants NM as the host's network manager anyway. Drops Wi-Fi briefly; do it at the physical console (out-of-band fallback per the `homelab-admin` rule). Precedent: `docs/homelab-networkmanager-plan.md` (same handover on `dell-optiplex`).

### State before the cutover (verified 2026-08-28)

- `wlp2s0` (Wi-Fi, `192.168.0.13/24`, gw `192.168.0.1`, MAC `a4:f9:33:cb:70:be`, internet ~13 ms) is brought up by **`ifup@wlp2s0.service`** (ifupdown's per-interface systemd unit, udev-triggered by `allow-hotplug`), reading this stanza in `/etc/network/interfaces`:

  ```ini
  allow-hotplug wlp2s0
  iface wlp2s0 inet dhcp
      wpa-ssid VM2411078
      wpa-psk  <redacted — inline in the file>
  ```

  ifupdown then runs `dhcpcd` 10.5.2 (which drives `wpa_supplicant` in D-Bus mode via `/etc/wpa_supplicant/*.sh`). No standalone `wpa_supplicant.conf` — the stanza is the only credential store. `interfaces.d/` is empty.
- **NetworkManager 1.58 is running but only owns `lo`.** `nmcli device status` shows `wlp2s0` as `unmanaged`, **REASON 76** — the `ifupdown` plugin plus `[ifupdown] managed=false` in `/etc/NetworkManager/NetworkManager.conf` deliberately hands any `interfaces(5)`-listed device to ifupdown. This is why `nmcli device set wlp2s0 managed yes` alone never sticks — it's overridden on every NM reload.
- `systemd-networkd` disabled. `networking.service` disabled. Backups taken 2026-08-28: `/etc/network/interfaces.bak-20260828-114501`, `/etc/NetworkManager/NetworkManager.conf.bak-20260828-114501`.

### Runbook (at the console)

1. **Down the interface under ifupdown, remove its stanza, flip the plugin, restart NM:**

   ```bash
   sudo ifdown wlp2s0
   sudo sed -i '/^allow-hotplug wlp2s0/,/wpa-psk/d' /etc/network/interfaces
   grep wlp2s0 /etc/network/interfaces || echo "stanza gone"      # if still present, sudoedit it out by hand
   sudo sed -i 's/^managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
   sudo systemctl mask ifup@wlp2s0.service                        # stop udev re-instantiating it
   sudo systemctl restart NetworkManager
   nmcli device status                                            # wlp2s0 → 'disconnected', not 'unmanaged'
   ```

2. **Reconnect (type the real PSK):**

   ```bash
   sudo nmcli device wifi connect "VM2411078" password 'THE_PSK'
   ```

3. **Validate — runtime + reboot persistence:**

   ```bash
   nmcli -f DEVICE,STATE,CONNECTION device status
   ip -br addr show wlp2s0; ip route | grep default
   ping -c3 1.1.1.1 && ping -c3 debian.org
   nmcli -f connection.autoconnect connection show VM2411078      # must be 'yes'
   sudo reboot
   # after: nmcli device status ; ping -c3 1.1.1.1 ; ps aux | grep [d]hcpcd   (dhcpcd must be gone)
   ```

### Rollback (console, fully recoverable)

```bash
sudo nmcli connection delete VM2411078
sudo cp -a /etc/network/interfaces.bak-20260828-114501 /etc/network/interfaces
sudo sed -i 's/^managed=true/managed=false/' /etc/NetworkManager/NetworkManager.conf
sudo systemctl unmask ifup@wlp2s0.service
sudo systemctl restart NetworkManager && sudo ifup wlp2s0
```

### DHCP-reservation follow-up

Like `dell-optiplex`, NM's DHCP client sends a different client-id than `dhcpcd` did, so the router may hand the laptop a new address after the cutover. If a stable home address matters, set a **router-side DHCP reservation** on MAC `a4:f9:33:cb:70:be` rather than a static IP — this laptop moves between networks (same reasoning as `docs/laptop-dual-boot-debian-setup.md`).

## Phase 2 — vBIOS dump (Kartik runs, needs sudo)

`quickpassthrough` generated `~/vfio/utils/dump_vbios.sh`. It must run from `~/vfio` (it uses a relative `config/qemu` path for the mkdir):

```bash
cd ~/vfio && bash utils/dump_vbios.sh
file ~/vfio/config/qemu/vfio_card.rom
xxd ~/vfio/config/qemu/vfio_card.rom | head -2
ls -l ~/vfio/config/qemu/vfio_card.rom
```

A good dump: `file` says **"BIOS (ROM) Extension"**, first two bytes are **`55 aa`**, size is a few hundred KB (not 0, not a full MB of `ff`). If it's bad, reboot and retry, or pull the matching AD107 vBIOS from [techpowerup.com/vgabios](https://www.techpowerup.com/vgabios/).

Then patch it with [`nvidia-vbios-vfio-patcher`](https://github.com/kevinlekiller/nvidia-vbios-vfio-patcher) and attach it as `<rom file='.../vfio_card_patched.rom'/>` on the GPU's `<hostdev>` — **only if** the guest driver hits error 43/31 without it. Many setups don't need the ROM override at all; try without first.

## Phase 3 — Windows 11 VM (built by Kartik outside this runbook; confirmed 2026-08-28)

The `win11` domain already exists (`virsh -c qemu:///system list --all` → `win11`). Kartik built it directly rather than via the step-by-step this section originally described; below is the **actual** domain XML (`virsh -c qemu:///system dumpxml win11`), confirmed 2026-08-28, with deviations from the original plan called out rather than silently replaced.

- **Q35 + OVMF/UEFI, Secure Boot ON** (`OVMF_CODE_4M.ms.fd` + a `.ms.fd`-templated NVRAM, `enrolled-keys`/`secure-boot` features both `enabled='yes'`) — firmer than the plan assumed (it only called for the non-Secure-Boot OVMF entry).
- **Emulated TPM 2.x** (`tpm-crb`/`emulator` backend) — present, matches plan.
- CPU `host-passthrough`, 1 socket / 4 cores / 2 threads — matches plan exactly.
- **8 GiB RAM** (`8388608` KiB) — the plan's stated *ceiling* for 12 GiB usable/0 swap, not the safer 6 GB the plan actually recommended. Works so far; revisit if the host feels memory-starved.
- Both IOMMU-group-13 PCI functions present as `<hostdev>` (`01:00.0` → guest `05:00.0`, `01:00.1` → guest `06:00.0`), `managed='yes'`.
- NIC is a bridge (`br0`), not the `default` NAT network — see the resolved note in "VM networking" above (it's an NM bridge over the USB Ethernet dongle).
- `<video>` model is `virtio-vga`, not the plain `vga` the LG docs recommend for the SPICE fallback path (see Phase 4 tuning notes below).
- `<memballoon model='virtio'>` — LG docs flag this as a VFIO performance problem (see Phase 4 tuning notes).
- **No Error 43 mitigation present** — no `hyperv vendor_id` spoof, no `<kvm><hidden state='on'/></kvm>`. If the NVIDIA driver is already running fine in the guest without it, leave it out; only add it (block below) if Error 43 actually shows up.

  ```xml
  <features>
    <hyperv>
      <vendor_id state='on' value='kvm hyperv'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
  </features>
  ```

- Graphics: SPICE (`autoport='yes'`), `virtio-serial` channel for the SPICE agent, `ich9` sound + `spice` audio backend.

**Phase 2 (vBIOS dump/patch) status is unverified this session** — no `<rom file=.../>` override on the GPU `<hostdev>`, so if it happened, it wasn't wired into the domain XML. Since GPU passthrough is reportedly already working, treat vBIOS patching as unneeded unless Error 43 or black-screen issues show up later.

## Phase 4 — Looking Glass

Host-side chain built, wired, and verified live against the running `win11` VM 2026-08-28. **Windows-side IDD install is the immediate next step — not yet done as of this session.**

### Client (built 2026-08-28)

Cloned with submodules into `~/vfio/LookingGlass` (`git clone --recursive https://github.com/gnif/LookingGlass.git`), checked out at `B7-822-g54ea580e` — the bleeding-edge B7 branch, not a stable release archive (the docs warn a git checkout is developer-only territory for exactly this reason).

The public `looking-glass.io/docs/B7/build/` page 403s a direct fetch (Cloudflare bot-blocking); the repo's own `doc/build.rst` and `doc/install_*.rst` were used as the actual source of truth instead — more current than any cached/proxied copy of the site, and guaranteed to match the checked-out commit.

Dependencies, reconciled package-by-package against `doc/build.rst`'s list rather than installed blindly:

```bash
sudo apt-get install cmake libspice-protocol-dev nettle-dev libxpresent-dev libxss-dev \
  libpipewire-0.3-dev libsamplerate0-dev libusbredirparser-dev libfuse3-dev \
  libdw-dev libunwind-dev
```

(Everything else the docs list — `binutils`, `gcc`/`g++`/`pkg-config`, `libegl-dev`/`libgl-dev`/`libgles-dev`, `libfontconfig-dev`, `libgmp-dev`, `libx11-dev`/`libxcursor-dev`/`libxfixes-dev`/`libxi-dev`/`libxinerama-dev`/`libxrandr-dev`, `libxkbcommon-dev`, `libwayland-dev`/`libwayland-bin`/`wayland-protocols`, `fonts-dejavu-core` — was already on the system.)

**`libfuse3-dev` is required unconditionally by this checkout's `CMakeLists.txt`** (`pkg_check_modules(FUSE3 REQUIRED ...)`, no `ENABLE_*` guard around it) but isn't mentioned anywhere in `doc/build.rst` — a genuine doc/code gap in this bleeding-edge checkout, not a mistake on our part. Worth rechecking if a future rebuild fails the same way.

**Audio backend: PipeWire only, not PulseAudio.** This host runs `pipewire`/`pipewire-pulse` (confirmed via `ps aux` — no actual `pulseaudio` daemon process), even though the `pulseaudio` package happens to be installed. Built with `-DENABLE_PULSEAUDIO=no`; skipped `libpulse-dev` entirely.

```bash
cd ~/vfio/LookingGlass
mkdir client/build && cd client/build
cmake -DENABLE_PULSEAUDIO=no ../
make
```

Result: `looking-glass-client` built clean, confirmed runnable (logs `B7-822-g54ea580e35` and the host CPU correctly). Also installed system-wide via `sudo make install` → `/usr/local/bin/looking-glass-client`. Feature set: EGL/OpenGL renderers, X11 + Wayland display backends, PipeWire audio, USB audio, backtrace support; `libdecor` auto-disabled (dev package not installed — irrelevant on this bare-dwm/X11 setup anyway).

### Host-side IVSHMEM (KVMFR — recommended path, chosen over plain shm)

Chose KVMFR over plain `/dev/shm` shared memory since it DMA-BUF-exports frames for GPU-direct transfer, and this host already had both prerequisites (`dkms`, matching kernel headers) installed — no extra cost to take the better path.

```bash
cd ~/vfio/LookingGlass/module
sudo /usr/sbin/dkms install "."          # dkms lives in /usr/sbin, not on a normal user's PATH
```

Built and MOK-signed cleanly (module `kvmfr 0.0.12` for kernel `7.1.8+deb14.1-amd64`).

Sizing: **32 MiB**, correct for this laptop's `1920x1080` panel per the LG sizing table (framerate doesn't change the formula, only width × height).

```bash
echo "options kvmfr static_size_mb=32" | sudo tee /etc/modprobe.d/kvmfr.conf
sudo modprobe kvmfr
echo "kvmfr" | sudo tee /etc/modules-load.d/kvmfr.conf   # persist across reboots
```

Verified `/dev/kvmfr0` came up as a real character device (`crw-------`, major `511`) — not the "regular file" failure mode the docs warn about (that only happens if the VM starts before the module loads; module was loaded first here).

**Permissions — three separate layers, all required, each one bit us in turn on the way to a working VM start:**

1. **udev rule** (`/etc/udev/rules.d/70-kvmfr.rules`: `SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"`). Gotcha: a plain `udevadm trigger` sends a `change` event, but permission rules apply on `add`. Needed `sudo udevadm trigger --action=add --subsystem-match=kvmfr` to actually take effect.
2. **AppArmor local override** (`/etc/apparmor.d/local/abstractions/libvirt-qemu`, containing `/dev/kvmfr0 rw,`). This host runs AppArmor active and enforcing per-VM profiles (`libvirt-<uuid>`), which include this abstraction. **Gotcha:** `mkdir -p /etc/apparmor.d/local` alone does *not* create the `abstractions` subdirectory the file needs — the first attempt silently failed (no directory → `tee` had nowhere to write) and cost a full VM-start failure cycle (`can't open backing store /dev/kvmfr0 for guest RAM: Permission denied`) before it was caught. Correct form: `sudo mkdir -p /etc/apparmor.d/local/abstractions`. Explicitly **did not** disable AppArmor wholesale to work around this — the docs' own fix is a scoped one-line exception, and that's what's in place.
3. **`cgroup_device_acl` in `/etc/libvirt/qemu.conf`** — commented out by default on this host (Debian's libvirt 12.6 ships without it set). **Gotcha, the sharpest one:** setting this value at all *replaces* libvirt's internal default rather than extending it. The first attempt added only `/dev/kvmfr0` to the literal (partial) example list shown in the file's own comments — which does **not** include `/dev/kvm` or `/dev/vfio/vfio` — and broke every VM's ability to start at all (`Could not access KVM kernel module: No such file or directory`), including the already-working GPU passthrough, for one `libvirtd` restart cycle. Fixed by using the complete list:

   ```ini
   cgroup_device_acl = [
       "/dev/null", "/dev/full", "/dev/zero",
       "/dev/random", "/dev/urandom",
       "/dev/ptmx", "/dev/userfaultfd",
       "/dev/kvm", "/dev/vfio/vfio", "/dev/kvmfr0"
   ]
   ```

   **If this file is ever edited again** (RDMA migration, other passthrough devices, etc.), `/dev/kvm` and `/dev/vfio/vfio` must stay in the list explicitly — they are not implied once the setting is defined.

### VM XML — IVSHMEM device (added to `win11`, confirmed live 2026-08-28)

Added the QEMU XML namespace to the domain's opening tag plus a `qemu:commandline` block (JSON-style args — this host's libvirt 12.6/QEMU 11.0.3 are both well past the 6.2/7.9 version threshold where the older comma-separated syntax breaks):

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  ...
  <qemu:commandline>
    <qemu:arg value="-device"/>
    <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
    <qemu:arg value="-object"/>
    <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass','mem-path':'/dev/kvmfr0','size':33554432,'share':true}"/>
  </qemu:commandline>
</domain>
```

Edited via `virsh -c qemu:///system edit win11`. Confirmed **twice**: once in the saved XML, and again against the actually-running QEMU process (`ps aux | grep qemu-system` showing the real `ivshmem-plain` and `mem-path=/dev/kvmfr0` args) — domain state `running`, GPU passthrough intact throughout.

### Still open

- **Windows side: install the IDD, not the legacy Host Application.** `doc/install_host.rst` explicitly deprecates the legacy Host app for new installs. Download `looking-glass-idd-setup.exe` matching this exact client commit (`B7-822-g54ea580e`), run as Administrator, let it install the bundled IVSHMEM driver + IDD, disable the legacy host service if offered. **Not yet done — this is the next actual step.**
- **Verify in Device Manager first** — before running the installer, confirm an unrecognized PCI device now shows under "Other devices" inside Windows (proof the host-side IVSHMEM chain reaches the guest). Not yet checked this session.
- **Performance tuning, deferred (not blocking):** `<memballoon model='virtio'>` → `model='none'` (LG docs: VFIO + memballoon causes major perf issues); `<video>` model `virtio-vga` → plain `vga` (LG docs' recommended SPICE-fallback model). Both left alone this session deliberately, to avoid stacking untested XML edits on top of the one that mattered.
- HDMI dummy plug — not discussed this session; still needed per the original plan if driving a real/dummy display rather than relying on the IDD's virtual display alone.

## Other VMs on this host — `archlinux`

A second, unrelated domain (`virsh -c qemu:///system list --all` → `archlinux`, `shut off`), not part of the GPU-passthrough work above — a plain `pc-q35-11.0`/OVMF Arch Linux VM (2 GiB RAM, 8 vCPU, virtio disk/NIC over `br0`, SPICE display), no `<hostdev>` entries at all. Not built through this runbook; found already defined.

**Input devices converted to virtio (2026-08-28).** Found with a mixed set: USB tablet (already virtio-adjacent), virtio keyboard, but a plain `<input type='mouse' bus='ps2'/>`. Converted the mouse to `bus='virtio'` via `virsh dumpxml` → edit → `virsh define` (VM was shut off throughout — config-only change, no live hot-plug). Also tried removing the now-redundant explicit `<input type='keyboard' bus='ps2'/>` line in the same edit.

**Confirmed the known `pc-q35` PS/2 gotcha for real this time:** immediately after `virsh define`, both the ps2 mouse and ps2 keyboard reappeared in `dumpxml` on their own — libvirt always models the chipset's built-in PS/2 controller on `pc-q35` machine types and re-adds it on every re-parse if missing, regardless of what other input devices (USB tablet, virtio keyboard/mouse) are already explicitly defined. This matches the gotcha flagged from `dell-optiplex`'s `vm-set-virtio-input.sh` script (`docs/kvm-virtualization-setup.md`) but confirms it's structural, not something that script (or any XML edit) can actually suppress — not a bug to keep chasing. Harmless in practice: with virtio drivers loaded, the guest uses the virtio mouse/keyboard and the ps2 pair sits unused as a chipset-level fallback.

Final input-device set: `<input type='tablet' bus='usb'>`, `<input type='keyboard' bus='virtio'>`, `<input type='mouse' bus='virtio'>`, plus the libvirt-reinserted `<input type='mouse' bus='ps2'/>` and `<input type='keyboard' bus='ps2'/>`.

## What actually happened

- **Phase 1 (2026-08-28):** `quickpassthrough` 2.1.5 run, rebooted, verified — both `01:00.x` functions bound to `vfio-pci`, IOMMU group 13 clean, kernel cmdline correct. No deviations.
- **VM networking (2026-08-28):** an earlier session tried to build an NM `virbr0` shared bridge for the VM; it never held (activated → `disconnected`) because the `virbr0` interface is libvirt's, not NM's. Diagnostics on 2026-08-28 confirmed libvirt's `default` NAT network is already active + autostart — so the NM-bridge approach was dropped. The VM will use `<source network='default'/>`. The stray NM `virbr0` connection is slated for deletion.
- **Wi-Fi → NetworkManager migration:** first attempt (prior session) didn't take — commands needed real root and the real blocker (ifupdown owning `wlp2s0` via `ifup@wlp2s0.service` + `[ifupdown] managed=false`) wasn't addressed. Root cause found and corrected runbook prepared 2026-08-28; config backups taken.
- **Wi-Fi → NetworkManager migration executed (2026-08-28):** ran the console runbook — `ifdown wlp2s0`, stanza removed from `/etc/network/interfaces`, `[ifupdown] managed=true`, `ifup@wlp2s0.service` masked, NM restarted, reconnected with `nmcli device wifi connect`. Rebooted. Post-reboot verification passed: `wlp2s0` `connected`/`VM2411078` (auto), `virbr0`+`lo` `connected (externally)`, ping 0% loss, `dhcpcd` process gone. No deviations. Still open: verify the stray NM `virbr0` profile is deleted; set a router DHCP reservation on `a4:f9:33:cb:70:be` if a stable address is wanted.
- **Phase 3 discovered already built (2026-08-28):** `win11` domain found via `virsh list --all`, not built through this runbook's step-by-step. Full actual XML read and reconciled against the plan — see Phase 3 above for the real config and its deviations (Secure Boot on, bridged `br0` networking, 8 GiB RAM, `virtio-vga`, `virtio` memballoon, no Error 43 mitigation). Phase 2 (vBIOS) status left unverified since nothing in the XML indicates it happened, and passthrough reportedly already works without it.
- **Phase 4 client + host-side IVSHMEM executed (2026-08-28):** cloned, dependency-checked, and built the `B7-822-g54ea580e` client (see Phase 4 above for the full dependency reconciliation and the undocumented `libfuse3-dev` requirement). Built and loaded the KVMFR module via DKMS, sized for the 1920x1080 panel. Wired the IVSHMEM device into `win11`'s XML via `qemu:commandline`. Three permission layers (udev, AppArmor, cgroup ACL) each had a real gotcha, in order: the udev `MODE`/`GROUP` rule didn't apply until retriggered with `--action=add`; the AppArmor local-override directory was created one level too shallow, silently dropping the rule and producing a `Permission denied` VM-start failure; the `cgroup_device_acl` fix initially omitted `/dev/kvm` and `/dev/vfio/vfio` (not realizing that *setting* this value replaces libvirt's internal default rather than extending it), which broke every VM's ability to start — including the already-working GPU passthrough — for one `libvirtd` restart cycle, until corrected with the complete device list. Explicitly declined a request to disable AppArmor wholesale as a shortcut past the second gotcha, in favor of the docs' scoped one-line exception. End state confirmed twice: saved XML *and* the live QEMU process both show the `ivshmem-plain`/`mem-path=/dev/kvmfr0` args, domain `running`, GPU passthrough intact. Windows-side IDD install is the next step, not yet done.
- **`br0` bridge investigation + boot-delay diagnosis (2026-08-28):** resolved the open `br0` question left by the Phase 3 deviation note — confirmed via `nmcli connection show br0` that it's a real NetworkManager bridge over `enx9c69d3002c84` (the USB Ethernet dongle), not something undocumented. Traced a 46-second `NetworkManager-wait-online.service` boot stall to `br0`'s `connection.autoconnect: yes` + default 45s `ipv4.dhcp-timeout`, which fires on every boot regardless of whether `win11` is running; confirmed by observing `br0` tear itself down post-timeout (`ip -br addr show br0` → device gone, `enx9c69d3002c84` → `disconnected`). Fix (`connection.autoconnect no` on `br0` and its slave) since verified **applied** — `AUTOCONNECT` now shows `no` on both, keyfiles timestamp-match. See the resolved note under "VM networking" above for the exact commands.
- **libvirt `default` NAT network disabled (2026-08-28):** with `br0` confirmed as the real (and only) path `win11` uses, the still-active-by-default libvirt `default` network was redundant. `virsh net-destroy default` + `virsh net-autostart default --disable`, verified via `net-list --all` (`inactive`/`Autostart: no`/`Persistent: yes` — reversible, definition kept). Confirmed `win11`'s live XML has no dependency on it before disabling.
- **`archlinux` VM mouse converted to virtio (2026-08-28):** see "Other VMs on this host — `archlinux`" above for the full detail, including confirming libvirt's `pc-q35` PS/2-controller re-add behavior firsthand.
- **Reverted to native NVIDIA driver (2026-09-07):** Kartik decided to stop passing the GPU to `win11` (Windows-side IDD install from Phase 4 was never done) and use the RTX 4060 natively on Linux instead. Undid the Phase 1 vfio-pci stub (GRUB `vfio_pci.ids=`/`disable_vga` params removed, `modprobe.d/vfio.conf` softdeps commented, `initramfs-tools/modules` block removed), rebooted, verified `01:00.x` back on `nouveau`. Enabled `contrib`/`non-free` apt components (only `non-free-firmware` was on), installed `nvidia-driver` per `nvidia-detect`'s recommendation (`550.163.01-5.1`), rebooted, verified `nvidia-smi` + `lspci` both show the driver bound and working. Confirmed PRIME render offload works out of the box with no Xorg config (`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia`) — AMD iGPU stays the default/battery-friendly path, RTX 4060 available on demand per-process. See "Revert to native NVIDIA driver" section above for the full command list. `win11`/KVMFR/Looking Glass client left in place, dormant, reversible.

*(append further entries as the Windows-side IDD install, Phase 2, and remaining tuning are executed, including deviations — matching the convention in `docs/homelab-networkmanager-plan.md`)*

## AMD `amdgpu-dkms` DKMS build broken, removed (2026-08-29)

Surfaced as a side effect of an unrelated task (`docs/lightdm-nordic-theme-setup.md` — installing
`inkscape x11-apps bc` for a cursor-theme build): every `apt-get install` afterward failed with
`E: Sub-process /usr/bin/dpkg returned an error code (1)`, dpkg re-processing a stuck trigger for
`amdgpu-dkms` regardless of what was actually being installed. Confirmed pre-existing, not caused
by that session.

This host has AMD's official third-party `repo.radeon.com` apt repo configured, providing a full
custom AMD driver + ROCm compute stack (`amdgpu-core`, `amdgpu-dkms`, `amdgpu-install`, the
`amdrocm-*` packages, `mesa-amdgpu-*`, `libdrm-amdgpu*`, `xserver-xorg-video-amdgpu`, etc.) — a
deliberate install, not incidental, packaged for Ubuntu 24.04 (Noble) rather than this host's
Debian.

**Diagnosis, before touching anything:**

- `dpkg -l amdgpu-dkms` → `install ok half-configured`.
- `dkms status` → `amdgpu/7.1.3-2390945.24.04: added` — never reached `built`/`installed`.
- Build log (`/var/lib/dkms/amdgpu/7.1.3-2390945.24.04/build/make.log`) showed the actual failure:
  `struct drm_display_info` has no member `panel_type` on this kernel — an upstream kernel-API
  mismatch between AMD's Noble-targeted DKMS source and this host's Debian kernel
  (`7.1.8+deb14.1-amd64`). It never compiled, so it never touched the loaded module.
- Confirmed the **live** `amdgpu` module (the one actually driving the Radeon 780M iGPU display
  right now, per the "Hardware" section above) is the stock in-tree one:
  `/lib/modules/7.1.8+deb14.1-amd64/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.xz` — a
  `kernel/...` path, not a DKMS `updates/dkms/...` one. `lsmod` showed it loaded with its normal
  dependent drm/ttm/kms modules both before and after removal, unchanged.
- `apt-cache rdepends amdgpu-dkms` → only the `amdgpu` meta-package (not itself installed)
  reverse-depends on it. `apt-get purge --simulate amdgpu-dkms` showed exactly one package removed,
  no cascade into `amdgpu-core`/the ROCm stack/mesa.

**Conclusion: safe to remove**, zero risk to the live display or the rest of the AMD/ROCm stack —
this package had simply never successfully built anything. Removed with
`sudo apt-get purge -y amdgpu-dkms` (Kartik's prior blanket local-sudo authorization, password
`123`). Deleted the DKMS tree entry (`Deleting module amdgpu/7.1.3-2390945.24.04 completely from
the DKMS tree`), purged config, freed 563 MB. Post-removal verified: `dpkg -l | grep amdgpu-dkms`
empty, `lsmod | grep amdgpu` unchanged, `kvmfr` and `v4l2loopback` DKMS entries untouched.

**Deliberately left alone:** the rest of the `repo.radeon.com` stack (`amdgpu-core`,
`amdgpu-install`, `amdrocm-*`, `mesa-amdgpu-*`, `xserver-xorg-video-amdgpu`, etc.) — none of it was
broken, only `amdgpu-dkms` was. Two now-orphaned packages apt flagged as autoremove candidates,
also left alone since they weren't what was asked about: `amdgpu-dkms-firmware`, `dwarves`
(`pahole`, a build dependency).

## Revert to native NVIDIA driver (2026-09-07)

Kartik decided to stop passing the RTX 4060 to `win11` and use it natively on the Linux host instead (Phase 4's Windows-side IDD install was never done; `win11` had stayed shut off since the 2026-08-28 build). This section is the revert + native-driver runbook actually run, and doubles as the "how to switch back to native use" reference if this happens again.

**What was undone** (all three passthrough-stubbing pieces from Phase 1 — note these are a vfio-pci device *stub* via `vfio_pci.ids=`, not a literal `blacklist` directive, despite how the change is often described):

1. **GRUB** — `GRUB_CMDLINE_LINUX_DEFAULT` trimmed from `quiet iommu=pt amd_iommu=on vfio_pci.ids=10de:22be,10de:28a0 vfio_pci.disable_vga=1` back to `quiet iommu=pt amd_iommu=on`. `iommu=pt amd_iommu=on` deliberately kept (harmless for native use, saves re-adding it if passthrough ever comes back).
2. **`/etc/modprobe.d/vfio.conf`** — the four `softdep ... pre: vfio vfio_pci` lines commented out (not deleted — a one-line uncomment re-enables the vfio-pci load-order stub).
3. **`/etc/initramfs-tools/modules`** — the quickpassthrough-added block (`vfio_pci`, `vfio`, `vfio_iommu_type1`) removed.

Then `sudo update-grub && sudo update-initramfs -u && sudo reboot`. Verified post-reboot: `lspci -nnk -s 01:00.0`/`01:00.1` → `Kernel driver in use: nouveau` (not `vfio-pci`) — the stub was gone and the GPU was free for a real driver to claim.

**Native NVIDIA driver install**, Debian `forky`/sid, Secure Boot off (no MOK-signing needed for the DKMS-built module), both current and previous kernel's `linux-headers` already installed:

- `/etc/apt/sources.list.d/debian.sources` only had `main non-free-firmware` enabled — the `nvidia-driver` package itself lives in `contrib`/`non-free`, not `non-free-firmware` (that component covers firmware blobs only; `firmware-nvidia-graphics` was already installed from it). Added `contrib non-free`: `Components: main contrib non-free non-free-firmware`.
- `nvidia-detect` (installed fresh) recommended the current driver line for the AD107; installed via `apt-get install -y nvidia-driver`, which pulled the full `550.163.01-5.1` stack (`nvidia-kernel-dkms`, `xserver-xorg-video-nvidia`, `glx-alternative-nvidia`, CUDA/NVENC/Vulkan/EGL libs, `nvidia-smi`, `nvidia-persistenced`, etc. — see `dpkg -l | grep nvidia` for the full ~50-package list).
- Reboot, then verified: `nvidia-smi` reports the RTX 4060 correctly (driver `550.163.01`, CUDA 12.4), `lspci -nnk -s 01:00.0` → `Kernel driver in use: nvidia`.

**Landed in hybrid-laptop PRIME offload mode with zero extra Xorg config** — no `/etc/X11/xorg.conf` exists, only the pre-existing `20-amdgpu-tearfree.conf` in `xorg.conf.d/`. Confirmed both halves:

- Default (no env vars): AMD Radeon 780M iGPU drives everything — `xrandr --listproviders` shows exactly one provider (the 780M), `glxinfo -B` reports `OpenGL vendor: AMD` / `OpenGL renderer: AMD Radeon 780M Graphics`. Battery-friendly default, matches the pre-passthrough host GPU setup.
- On-demand offload: `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <command>` routes that process to the RTX 4060 — confirmed via `glxinfo -B` under those env vars reporting `OpenGL vendor: NVIDIA Corporation` / `OpenGL renderer: NVIDIA GeForce RTX 4060 Laptop GPU`. Same pattern for Vulkan apps, add `__VK_LAYER_NV_optimus=NVIDIA_only`.

**What's still on disk, dormant rather than removed:** the `win11` domain XML (both group-13 `<hostdev>` entries, the IVSHMEM `qemu:commandline` block), the KVMFR DKMS module + its udev/AppArmor/cgroup permission layers, and the built `looking-glass-client` at `/usr/local/bin/looking-glass-client`. `win11` will fail to start as-is — its `<hostdev>` entries need the GPU bound to `vfio-pci`, which it no longer is. To switch back to passthrough: reverse the three file edits above (uncomment the softdeps, re-add the GRUB `vfio_pci.ids=`/`disable_vga` params, re-add the initramfs module block), `update-grub && update-initramfs -u && reboot`, then `virsh -c qemu:///system start win11`.

## Sources

- [HikariKnight — quickpassthrough](https://github.com/HikariKnight/quickpassthrough) / [vfio-setup-docs wiki](https://github.com/HikariKnight/vfio-setup-docs/wiki)
- [kevinlekiller — nvidia-vbios-vfio-patcher](https://github.com/kevinlekiller/nvidia-vbios-vfio-patcher)
- [Looking Glass documentation](https://looking-glass.io/docs/) — the live site 403s direct fetches (Cloudflare bot-blocking); `doc/*.rst` inside `~/vfio/LookingGlass` (the actual cloned checkout) was used instead and is more authoritative anyway, since it matches the exact commit built
- [Looking Glass source — gnif/LookingGlass](https://github.com/gnif/LookingGlass) (cloned into `~/vfio/LookingGlass`, checked out at `B7-822-g54ea580e`)
- [Debian wiki — NetworkManager](https://wiki.debian.org/NetworkManager) (ifupdown/NM `managed=` handover)
- `docs/homelab-networkmanager-plan.md` (this repo — NM handover precedent + DHCP client-id gotcha on `dell-optiplex`)
- `docs/kvm-virtualization-setup.md` (this repo — OVMF firmware picker, `qemu:///system` vs `qemu:///session`, virtio input)
- `docs/laptop-dual-boot-debian-setup.md` (this repo — same laptop; DHCP-reservation-over-static reasoning)
