# Raspberry Pi 5 on Arch Linux ARM

How to get Arch Linux ARM (ALARM) running on a Raspberry Pi 5 as a headless homelab host. It covers building the card, swapping the kernel, first boot, hardening, NVMe boot, EEPROM management, and recovery. This is a generic install guide. The existing Debian Pi in this homelab is documented separately in `docs/raspberry-pi-host-setup.md`, so don't mix the two up.

> **This wipes the target disk.** The homelab's existing Pi 5 (`raspberrypi`, `192.168.0.166`) runs Debian with live services (see `docs/raspberry-pi-host-setup.md`). Don't run sections 5 or 10 against its SD card or NVMe drive unless you mean to replace that host, and back it up first (section 11, Backups).

Package names, versions and file contents below were checked against the ALARM mirror, the `archlinuxarm/PKGBUILDs` repo and the stock rootfs tarball on 2026-11-06. Nothing here has been run end-to-end on a real Pi 5 yet. Treat it as a researched procedure, not a verified install log, and record the first real run at the bottom.

## 1. Support status: read this first

ALARM has no dedicated Raspberry Pi 5 image. The only 64-bit Pi image is `ArchLinuxARM-rpi-aarch64-latest.tar.gz`. It's built around U-Boot and the mainline `linux-aarch64` kernel, and its own platform page still describes it in terms of the Pi 4. The working approach, which the community has used since late 2023, is to:

1. Extract that generic aarch64 rootfs.
2. Remove `uboot-raspberrypi` and `linux-aarch64`.
3. Install `linux-rpi`, the Raspberry Pi Foundation kernel fork, which the Pi 5 firmware boots directly with no U-Boot.

As of 2026-11-06, the repos hold everything needed:

| Package | Repo | Version | Role |
|---|---|---|---|
| `linux-rpi` | core | 6.18.60-1 | Foundation kernel, 4K pages, boots Pi 4 and Pi 5. Installs `kernel8.img`, DTBs, overlays, `config.txt`, `cmdline.txt` |
| `linux-rpi-16k` | core | 6.18.60-1 | Same kernel built from `bcm2712_defconfig` with 16K pages. Pi 5 only. Still installs as `kernel8.img` (PKGBUILD `_kernel=kernel8.img`), so every `kernel8.img` reference below applies to both. Conflicts with `linux-rpi` |
| `raspberrypi-bootloader` | alarm | 20261102-1 | GPU firmware files (`start*.elf` and friends) in `/boot` |
| `firmware-raspberrypi` | alarm | 20260311-1 | Wi-Fi/Bluetooth firmware for the onboard CYW43455 |
| `rpi5-eeprom` | alarm | 20261103-1 | `rpi-eeprom-update` and `rpi-eeprom-config` plus Pi 5 bootloader images |
| `raspberrypi-utils` | alarm | 20261102-1 | `vcgencmd`, `pinctrl` and the other userspace tools |

Both kernels install `/boot/config.txt` and `/boot/cmdline.txt` as pacman `backup` files. Your edits survive upgrades, and new upstream defaults show up as `.pacnew` files.

### 4K or 16K kernel

Use `linux-rpi` (4K pages) unless you have a reason not to. The 16K kernel is somewhat faster on Pi 5, but software that assumes 4K pages breaks on it. Known breakage includes some jemalloc-linked binaries, some container images, Box64/FEX-style emulators and older Electron/Chromium builds. For a homelab box running containers, compatibility beats a few percent of speed. You can swap later with one `pacman -S` because the two packages conflict.

## 2. Hardware checklist

- Raspberry Pi 5 (any RAM size).
- 5 V / 5 A USB-C supply (the official 27 W unit). On a 3 A supply the firmware limits USB current to 600 mA and refuses to boot from USB. If you'll boot from USB, use a real 5 A supply. Pressing the power button once after a refused USB boot retries it for that boot only. Don't set `PSU_MAX_CURRENT=5000` on a 3 A supply to force it: that invites the brown-outs the troubleshooting table describes.
- microSD card (A2-rated, 32 GB or more), or an NVMe drive on an M.2 HAT/base. You'll need a card or USB-NVMe enclosure reader for the build host.
- Active Cooler or a case fan. The firmware runs the fan automatically: off below 50 °C and 100 % at 75 °C. Soft throttling starts at 80 °C.
- Wired Ethernet for the first boot. Wi-Fi isn't configured in the stock image.
- Optional but recommended for a headless host: a Raspberry Pi Debug Probe or 3.3 V USB-UART on the 3-pin JST UART connector between the HDMI ports (`ttyAMA10`). It's your out-of-band console when SSH or networking breaks.

## 3. Pre-flight: update the bootloader EEPROM

Older Pi 5 boards shipped with bootloaders that predate decent NVMe and USB support. Update the EEPROM before installing anything. Either do it later from Arch with `rpi5-eeprom` (section 9), or do it first with no OS at all:

1. On the build host, open `rpi-imager` (in Arch `extra`). Choose **Misc utility images → Bootloader (Pi 5 family) → SD card boot** (or **NVMe/USB boot**) and write it to a spare card.
2. Boot the Pi 5 from that card and wait for the green LED to blink steadily, or for the HDMI screen to go green.
3. Power off and remove the card.

## 4. Prepare the build host (x86_64 Arch/CachyOS)

You'll chroot into the aarch64 rootfs on the x86_64 laptop with QEMU user-mode emulation. That way the kernel swap happens with real `pacman` before the Pi ever boots. This avoids two problems: guessing whether the stock U-Boot and mainline kernel will boot a Pi 5, and copying kernel files around by hand without their modules.

```bash
sudo pacman -S --needed arch-install-scripts qemu-user-static qemu-user-static-binfmt dosfstools e2fsprogs libarchive wget
sudo systemctl restart systemd-binfmt
ls /proc/sys/fs/binfmt_misc/ | grep aarch64        # expect: qemu-aarch64
```

## 5. Partition, format and extract

Find the card. Get this wrong and you wipe the wrong disk.

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

In the examples the card is `/dev/sdX`. A built-in reader shows up as `/dev/mmcblk0`, with partitions `p1` and `p2`.

```bash
DEV=/dev/sdX
P=""            # set P=p for /dev/mmcblkN or /dev/nvmeNnM (partitions are ...p1, ...p2)
# unmount anything the desktop auto-mounted, then confirm nothing is mounted
sudo swapoff "$DEV"?* 2>/dev/null
lsblk -nlo MOUNTPOINTS "$DEV" | command grep '^/' | sort -r | while read -r m; do sudo umount "$m"; done
lsblk -o NAME,MOUNTPOINTS "$DEV"              # MOUNTPOINTS column must be empty
sudo wipefs -a "$DEV"
sudo sfdisk "$DEV" <<'EOF'
label: dos
,1G,c
,,L
EOF
sudo mkfs.vfat -F 32 -n PIBOOT "${DEV}${P}1"
sudo mkfs.ext4 -L piroot "${DEV}${P}2"

sudo mkdir -p /mnt/pi
sudo mount "${DEV}${P}2" /mnt/pi
sudo mkdir -p /mnt/pi/boot
sudo mount "${DEV}${P}1" /mnt/pi/boot
```

Download and verify the rootfs. It was about 850 MB as of 2026-11-06, last modified 2026-08-05.

```bash
cd ~/Downloads
wget http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz{,.sig}
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6
gpg --verify ArchLinuxARM-rpi-aarch64-latest.tar.gz.sig ArchLinuxARM-rpi-aarch64-latest.tar.gz
# expect: "Good signature", made by key 68B3537F39A313B3E574D06777193F152BDBE6A6
```

The download is plain HTTP and redirects to a mirror, so check the signature, not just the `.md5`. An MD5 file fetched from the same place only catches corruption, not tampering. The key ID above is the release and package signing key listed on archlinuxarm.org's downloads page.

Extract it as root so ownership, permissions and xattrs are preserved. `sudo bsdtar` runs with real uid 0, which is enough. ALARM's "not via sudo" warning targets setups where sudo is configured to drop privileges.

```bash
sudo bsdtar -xpf ArchLinuxARM-rpi-aarch64-latest.tar.gz -C /mnt/pi
sync
```

## 6. Swap U-Boot and the mainline kernel for `linux-rpi`

```bash
sudo arch-chroot /mnt/pi
```

Everything below runs inside the chroot as aarch64 under QEMU. It's slow, especially the key generation.

```bash
pacman-key --init
pacman-key --populate archlinuxarm

pacman -R --noconfirm linux-aarch64 uboot-raspberrypi
pacman -Syu --overwrite '/boot/*' linux-rpi raspberrypi-bootloader firmware-raspberrypi rpi5-eeprom raspberrypi-utils dosfstools
```

If pacman fails to download with sandbox or Landlock errors under emulation, re-run it with `--disable-sandbox`. That's a chroot-only workaround, so don't make it permanent in `pacman.conf`.

Check that the boot partition now holds what the Pi 5 firmware expects:

```bash
ls /boot/kernel8.img /boot/config.txt /boot/cmdline.txt /boot/bcm2712-rpi-5-b.dtb /boot/overlays/README
ls /boot/kernel_2712.img 2>/dev/null && echo 'REMOVE IT: Pi 5 firmware prefers kernel_2712.img over kernel8.img'
```

Leave the chroot open for section 7.

### Why initramfs needs a second pass

`config.txt` loads `initramfs-linux.img`, which `mkinitcpio` generates through the package hook. Inside the chroot, mkinitcpio's `autodetect` hook reads the x86 host's `/sys`, not the Pi's, so the image it builds may lack modules the Pi needs. Both `linux-rpi` presets build only that one image (`PRESETS=('default')`), so there's no `-fallback` image to fall back on. Overwrite it with a generic, non-autodetected build before leaving the chroot:

```bash
KVER=$(basename "$(dirname "$(grep -lxE 'linux-rpi(-16k)?' /usr/lib/modules/*/pkgbase)")")
echo "$KVER"                                   # e.g. 6.18.60-1-rpi
mkinitcpio -k "$KVER" -S autodetect -g /boot/initramfs-linux.img
```

This generic image is bigger but carries every module. After first boot, `mkinitcpio -P` on the Pi replaces it with a trimmed image (section 8). Use the same three commands for any recovery done from the host chroot (section 14).

## 7. Boot configuration (still in the chroot)

### `cmdline.txt`: root by PARTUUID

The packaged `cmdline.txt` hard-codes `root=/dev/mmcblk0p2`. That's correct for an SD card under `linux-rpi`, but wrong the moment you move to NVMe or USB. Pin it to the partition's identity instead. Make this edit from the host after you `exit` the chroot, in the same terminal where `DEV` and `P` are set. See "Set root= and unmount" at the end of this section. The file must stay on a single line.

If you use the debug UART connector, add `console=ttyAMA10,115200` to that line.

### `fstab`

The stock `fstab` mounts `/dev/mmcblk0p1` on `/boot`. Switch it to filesystem labels so `/boot` is found regardless of device numbering:

```bash
cat > /etc/fstab <<'EOF'
# <file system>  <dir>  <type>  <options>                   <dump> <pass>
LABEL=PIBOOT     /boot  vfat    defaults,noatime             0      2
LABEL=piroot     /      ext4    defaults,noatime             0      1
EOF
```

### `config.txt`

The packaged defaults are fine: KMS graphics, auto-detected cameras and displays, and `arm_boost=1`. Add Pi 5 tweaks under the final `[all]` section only if they apply:

```ini
[all]
# Headless: no need for the second framebuffer
max_framebuffers=1
# Genuine 5 A supply that doesn't negotiate USB-PD: allow full USB current.
# Never set this on a 3 A supply (see section 2).
#usb_max_current_enable=1
# NVMe on a non-certified adapter: force the PCIe x1 port on, optionally at Gen 3
#dtparam=pciex1
#dtparam=pciex1_gen=3
# Charge an RTC battery on the J5 connector (rechargeable cells only)
#dtparam=rtc_bbat_vchg=3000000
```

### Network: fix the Ethernet match

This one will bite you headless. The stock `/etc/systemd/network/eth.network` matches only `Name=eth*`, but under `linux-rpi` systemd names the Pi 5's Ethernet `end0`. Without this fix the Pi boots with no DHCP lease and no SSH.

```bash
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
rm /etc/systemd/network/eth.network
```

### Hostname

```bash
echo pi5-arch > /etc/hostname
exit
```

### Set root= and unmount (on the host)

```bash
PARTUUID=$(sudo blkid -s PARTUUID -o value "${DEV}${P}2")
echo "$PARTUUID"                               # must not be empty, e.g. 1a2b3c4d-02
sudo sed -i "s|root=[^ ]*|root=PARTUUID=${PARTUUID}|" /mnt/pi/boot/cmdline.txt
cat /mnt/pi/boot/cmdline.txt
# root=PARTUUID=1a2b3c4d-02 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes
sudo umount -R /mnt/pi
sync
```

## 8. First boot

Insert the card, connect Ethernet, then power on. Find the DHCP lease on the router, or via the UART console, then connect:

```bash
ssh alarm@<pi-ip>          # password: alarm
su -                       # root password: root
```

Then, as root on the Pi:

```bash
# 1. Kill the default credentials immediately
passwd
passwd alarm               # or create your own user and delete alarm (below)

# 2. Get the clock right first: there's no RTC battery by default, and a wrong
#    date makes pacman reject signatures as "not valid yet" or expired
systemctl enable --now systemd-timesyncd
timedatectl set-timezone Europe/London
timedatectl                # wait for "System clock synchronized: yes"

# 3. Full update, then rebuild the initramfs against the real hardware
#    (one rebuild, against the final kernel)
pacman -Syu
mkinitcpio -P

# 4. Locale
sed -i 's/^#en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen && locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
```

Create a real admin user and retire `alarm`:

```bash
pacman -S --needed sudo
useradd -m -G wheel,video -s /bin/bash kartik
passwd kartik
EDITOR=nano visudo -f /etc/sudoers.d/10-wheel      # add: %wheel ALL=(ALL:ALL) ALL
```

From the host, run `ssh-copy-id kartik@<pi-ip>`. Confirm that key login and `sudo -v` both work, then log out of the `alarm` session completely. `userdel` refuses to remove a user with running processes, and your `su -` shell is one of them. Then:

```bash
ssh kartik@<pi-ip>
sudo loginctl terminate-user alarm     # ends lingering alarm processes, e.g. its systemd --user manager
sudo userdel -r alarm
```

Reboot once, then confirm you're actually running the Foundation kernel:

```bash
uname -r                                   # 6.18.x-…-rpi… (not -aarch64)
cat /proc/device-tree/model; echo          # Raspberry Pi 5 Model B Rev 1.x
ip -br addr show end0                      # UP with a DHCP address
```

## 9. Bootloader EEPROM from Arch

Run this section as root (`sudo -i`). `rpi5-eeprom` ships the tools and the bootloader images under `/usr/lib/firmware/raspberrypi/bootloader/{latest,default}/`. ALARM's PKGBUILD copies upstream's `firmware-2712/` there, so the upstream `bootloader-2712/` path doesn't apply. Its install message points to the ALARM forum's usage thread (t=15366). The release channel comes from `FIRMWARE_RELEASE_STATUS` in `/etc/default/rpi-eeprom-update`. Set it to `latest` for the newest NVMe and USB fixes. `nano`, used below, is pulled in as a dependency of `rpi5-eeprom`.

```bash
rpi-eeprom-update            # show current vs available
rpi-eeprom-update -a         # stage the newest image in the configured channel; applied on next reboot
                             # if it reports a flashrom error: pacman -S flashrom, then retry
reboot
```

Edit the bootloader config. This opens `$EDITOR`, then stages the change for the next reboot:

```bash
EDITOR=nano rpi-eeprom-config --edit
```

Useful keys:

| Key | Value | Meaning |
|---|---|---|
| `BOOT_ORDER` | `0xf461` | Pi 5 factory default (shipped in the bundled bootconf): SD, then NVMe, then USB, then loop. Read right to left |
| `BOOT_ORDER` | `0xf416` | NVMe first, then SD, then USB, then loop |
| `PCIE_PROBE` | `1` | Probe PCIe for NVMe even on adapters that aren't HAT+ certified |
| `PSU_MAX_CURRENT` | `5000` | Skip USB-PD negotiation and assume a 5 A supply. Only set this if the supply really is 5 A |

Boot-order digits: `1` SD, `2` network, `4` USB mass storage, `6` NVMe, `7` HTTP, `e` stop, `f` restart.

## 10. Moving to NVMe (optional, recommended for a homelab host)

SD cards wear out under database and container workloads. Once the SD install works, clone it to NVMe from the running Pi. Run everything here as root (`sudo -i`), since section 8 left you logged in as your admin user. The `wipefs` step destroys whatever is on the NVMe drive.

First, make sure the initramfs can reach NVMe. Check whether the kernel has both the PCIe host driver and the NVMe driver built in: `grep -E '/(pcie-brcmstb|nvme)\.ko$' /lib/modules/$(uname -r)/modules.builtin`. You need both lines, `pcie-brcmstb.ko` and `nvme.ko`. Matches like `nvme-core.ko` don't count. This works whether or not `/proc/config.gz` exists, since `linux-rpi` may build IKCONFIG as a module. If either is missing from that list, it's a module: attach the drive, then run `mkinitcpio -P` so `autodetect` picks up the loaded modules, and confirm them with `lsinitcpio /boot/initramfs-linux.img | grep -E 'nvme|brcmstb'`. Stop anything that writes heavily while you copy, such as databases and containers (`systemctl stop docker`, for example), so the clone is consistent.

```bash
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS     # expect nvme0n1, nothing mounted from it
wipefs -a /dev/nvme0n1                   # clears old GPT, including the backup header at the end
sfdisk /dev/nvme0n1 <<'EOF'
label: dos
,1G,c
,,L
EOF
mkfs.vfat -F 32 -n NVBOOT /dev/nvme0n1p1
mkfs.ext4 -L nvroot /dev/nvme0n1p2

mkdir -p /mnt/nv && mount /dev/nvme0n1p2 /mnt/nv
mkdir -p /mnt/nv/boot && mount /dev/nvme0n1p1 /mnt/nv/boot
rsync -aAXHx --info=progress2 --exclude={"/boot","/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /mnt/nv/
rsync -rt --modify-window=1 --info=progress2 /boot/ /mnt/nv/boot/   # vfat: no owners/ACLs/xattrs, 2 s timestamps
```

The new filesystems use different labels on purpose. With both devices attached, duplicate labels would make `/boot` mount from whichever device the kernel enumerates first. Point the NVMe copy at its own partitions:

```bash
NVUUID=$(blkid -s PARTUUID -o value /dev/nvme0n1p2)
sed -i "s|root=[^ ]*|root=PARTUUID=${NVUUID}|" /mnt/nv/boot/cmdline.txt
sed -i 's/LABEL=PIBOOT/LABEL=NVBOOT/; s/LABEL=piroot/LABEL=nvroot/' /mnt/nv/etc/fstab
# give the copy its own identity so the two installs never share a DHCP client ID or host keys
: > /mnt/nv/etc/machine-id                      # regenerated on the NVMe install's first boot
rm /mnt/nv/etc/ssh/ssh_host_*                   # sshdgenkeys.service recreates them before sshd starts
umount -R /mnt/nv
```

The NVMe install gets new SSH host keys, so remove the old entry on your client (`ssh-keygen -R <pi-ip>`) before connecting.

Set `BOOT_ORDER=0xf416` with `rpi-eeprom-config --edit`, add `PCIE_PROBE=1` if the adapter isn't HAT+, then reboot. Confirm you're on the NVMe drive:

```bash
findmnt -no SOURCE /          # /dev/nvme0n1p2
findmnt -no SOURCE /boot      # /dev/nvme0n1p1
```

Keep the SD card as a known-good recovery boot. With `0xf416`, the bootloader only falls through to SD when it can't load boot files from NVMe at all, for example when the drive is removed or its boot partition is unreadable. A kernel panic, wrong `root=` or emergency mode on NVMe happens after hand-off and does **not** fall back. To recover from those, remove or disconnect the NVMe drive, or fix it from the SD install.

## 11. Homelab hardening

Make each change with a second SSH session open, or with the UART console attached. A mistake in SSH or firewall config is how a headless Pi becomes a card-pulling job. Every command in this section runs as root, so start with `sudo -i` from your admin user.

### SSH

Use a drop-in rather than editing the packaged `sshd_config`:

```bash
cat > /etc/ssh/sshd_config.d/10-homelab.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers kartik
EOF
sshd -t && systemctl reload sshd
sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowusers'
```

If `sshd -T` doesn't reflect the drop-in, the packaged `sshd_config` is missing its `Include /etc/ssh/sshd_config.d/*.conf` line. Add the line at the top of the file and reload again.

Roll back by deleting the drop-in and running `systemctl reload sshd`.

### Firewall (nftables)

Set `LAN` to your own subnet **before** pasting. A wrong value locks SSH out as soon as the service starts, and stays locked out across reboots.

```bash
LAN=192.168.0.0/24          # your LAN, e.g. from: ip -4 route | grep -v default
pacman -S --needed nftables
cat > /etc/nftables.conf <<EOF
#!/usr/bin/nft -f
# Replace only this table. A full ruleset flush would also wipe Docker's tables on every restart.
table inet filter {}
delete table inet filter
table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
    ip6 saddr fe80::/10 udp dport 546 accept
    ip saddr ${LAN} tcp dport 22 accept
    ip6 saddr fe80::/10 tcp dport 22 accept
  }
  # accept: a drop here is final and would override Docker's own forwarding rules
  chain forward { type filter hook forward priority filter; policy accept; }
  chain output  { type filter hook output priority filter; policy accept; }
}
EOF
grep 'tcp dport 22' /etc/nftables.conf      # confirm the subnet expanded correctly
nft -c -f /etc/nftables.conf && systemctl enable --now nftables
nft list ruleset
```

The `udp dport 546` rule lets DHCPv6 replies in. They don't match conntrack state, so without it a stateful-DHCPv6 network silently loses IPv6 addressing. The forward chain accepts on purpose. A drop verdict in any base chain is final, so a drop policy here would black-hole container traffic no matter what Docker adds in its own tables. Docker filters forwarded traffic in its `DOCKER-*` chains. If the host never runs containers or routes, you can set the forward policy to `drop`. Roll back with `systemctl disable --now nftables && nft delete table inet filter`.

### Reduce SD wear and add swap

```bash
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=100M\n' > /etc/systemd/journald.conf.d/10-size.conf
systemctl restart systemd-journald

pacman -S --needed zram-generator
printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
systemctl daemon-reload && systemctl start systemd-zram-setup@zram0
swapon --show
```

### Hardware watchdog

The BCM2712 watchdog reboots a hung box. That's worth having on an unattended host:

```bash
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=10s\nRebootWatchdogSec=10s\n' > /etc/systemd/system.conf.d/10-watchdog.conf
systemctl daemon-reexec
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
```

Keep both values under about 15 s, the BCM watchdog's hardware maximum. Longer values can't be programmed into the hardware.

### Updates

Arch is rolling, and ALARM lags behind x86 Arch. Don't set up unattended `pacman -Syu`. Update by hand, then:

1. Check the archlinuxarm.org front page and forum for breakage notices first.
2. Merge any `.pacnew` files (`pacdiff`, from `pacman-contrib`), especially `/boot/config.txt.pacnew` and `/boot/cmdline.txt.pacnew`. Keep your `root=PARTUUID=` line.
3. Reboot after kernel or firmware updates, then confirm the running kernel is the installed one: `ls /usr/lib/modules/$(uname -r)` must exist, and `cat /usr/lib/modules/$(uname -r)/pkgbase` names the kernel package.
4. Keep the previous kernel package in `/var/cache/pacman/pkg/` (don't run `paccache -rk0`) so a bad kernel can be rolled back with `pacman -U`.

### Backups

From the build host, with the Pi powered off and the card or drive attached:

```bash
# pipefail (scoped to the subshell) stops zstd's exit 0 from hiding a dd read error
lsblk -o NAME,SIZE,MODEL,TRAN        # identify the Pi's medium
DEV=/dev/sdX                         # set to what lsblk showed
( set -o pipefail; sudo dd if="$DEV" bs=4M status=progress | zstd -T0 > pi5-arch-$(date +%F).img.zst ) && sync && echo BACKUP-OK
```

For live backups of the running host, `rsync -aAXHx` the root filesystem to the NAS (`-x` stays off Docker overlays and network mounts), then `rsync -rt --modify-window=1 /boot/` separately, using the section 10 excludes, so the kernel, `config.txt` and `cmdline.txt` are included.

## 12. Validation checklist

Run this after the install, and again after any kernel or EEPROM change. Run it as root (`sudo -i`): `ss -p`, `rpi-eeprom-update` and the journal need it for complete output.

```bash
cat /proc/device-tree/model; echo          # Raspberry Pi 5 Model B
uname -r                                   # -rpi kernel, not -aarch64
cat /usr/lib/modules/$(uname -r)/pkgbase      # linux-rpi or linux-rpi-16k
pacman -Q raspberrypi-bootloader rpi5-eeprom
getconf PAGESIZE                           # 4096 (linux-rpi) or 16384 (linux-rpi-16k)
findmnt -no SOURCE / ; findmnt -no SOURCE /boot
rpi-eeprom-update                          # BOOTLOADER: up to date
vcgencmd measure_temp; vcgencmd get_throttled   # throttled=0x0 means no under-voltage or throttling since this boot
ip -br addr; ss -tulpn                     # sshd plus systemd-networkd (DHCPv6 546/udp) and systemd-resolved (127.0.0.53:53, LLMNR 5355) are expected
systemctl --failed                         # 0 loaded units listed
journalctl -b -p err                       # no new errors
sshd -T | grep -Ei 'passwordauthentication|permitrootlogin'
nft list ruleset | head
swapon --show
```

If `vcgencmd` fails even as root, check that `/dev/vcio` exists and `raspberrypi-utils` is installed. If it fails only for your own user later, that user is missing the `video` group, which the `raspberrypi-utils` udev rule uses.

Report "config inspected" separately from "survived a reboot". Only a real power cycle proves `cmdline.txt`, `fstab`, `BOOT_ORDER` and the watchdog are correct.

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| HDMI shows the Pi 5 bootloader diagnostic screen, with no kernel | `kernel8.img` missing from `/boot`, or boot partition not FAT32 type `c` | Mount the card on the host and check `/boot` contents (section 6). Re-run the chroot install with `--overwrite '/boot/*'` |
| Kernel panics with `VFS: Unable to mount root fs` | Wrong `root=` in `cmdline.txt`, or `cmdline.txt` split over multiple lines | Fix the PARTUUID from the host (`blkid`). The file must be a single line |
| Boots, but no network or SSH | Stock `eth.network` doesn't match `end0` | Apply the section 7 network fix. Use the UART console or a keyboard to get in |
| Drops to emergency mode | `fstab` label mismatch (e.g. `PIBOOT` vs `NVBOOT`) | `blkid` versus `/etc/fstab`. Fix whichever is wrong |
| `pacman` signature errors | Keyring not initialised, or stale | `pacman-key --init && pacman-key --populate archlinuxarm`, then `pacman -Sy archlinuxarm-keyring && pacman -Su` (never `-Sy` alone, which leaves a partial upgrade) |
| `uname -r` shows a kernel `pacman` didn't install, and modules fail to load | A stale `kernel_2712.img` from Raspberry Pi OS or an earlier experiment is on `/boot`. Pi 5 firmware loads it before `kernel8.img` | Delete `/boot/kernel_2712.img`, then reboot |
| Random crashes, USB devices dropping, `get_throttled` not `0x0` | Under-voltage | Use the 5 A supply. Don't paper over it with `PSU_MAX_CURRENT` |
| NVMe not seen at boot | Non-HAT+ adapter, or old EEPROM | `PCIE_PROBE=1`, `dtparam=pciex1`, and update the EEPROM (section 9) |
| A container or app segfaults on startup | Running `linux-rpi-16k` | `pacman -S linux-rpi` (it replaces the 16K kernel), then reboot |
| Wi-Fi doesn't come up | This guide configures no wireless daemon, and `20-wired.network` matches only `en*`/`eth*`. Less often, `firmware-raspberrypi` is missing (`ip link` shows no `wlan0`) | `pacman -S --needed iwd firmware-raspberrypi`, `systemctl enable --now iwd`, connect with `iwctl`, then add a `.network` file matching `wlan*` with `DHCP=yes` |

## 14. Recovery and rollback

- **Bad kernel update:** attach the **broken** install's medium to the host. That's the NVMe drive (in a USB enclosure) if you migrated in section 10, not the SD fallback. In a fresh terminal, find it with `lsblk -o NAME,SIZE,MODEL,TRAN` and set `DEV=/dev/sdX; P=""` again (`P=p` for mmcblk or nvme names). Mount it **without** reformatting: `sudo mkdir -p /mnt/pi && sudo mount "${DEV}${P}2" /mnt/pi && sudo mount "${DEV}${P}1" /mnt/pi/boot && sudo arch-chroot /mnt/pi`. Don't re-run section 5's block, because it wipes the disk. Inside the chroot, `ls /var/cache/pacman/pkg/linux-rpi-[0-9]*` (or `linux-rpi-16k-[0-9]*` if that's your kernel) to find the previous version, then `pacman -U` that exact file. The suffix may be `.pkg.tar.xz` or `.pkg.tar.zst`. The package hook rebuilds the initramfs with the host's hardware autodetected, so rebuild it generically before leaving the chroot with the three commands from section 6 ("Why initramfs needs a second pass"). Once the Pi is up, run `mkinitcpio -P` on it. Switching between `linux-rpi` and `linux-rpi-16k` overwrites the same `initramfs-linux.img`, so the same applies.
- **Broken initramfs:** there is no fallback image. Mount the medium on the host as in the bullet above, `arch-chroot` in, and rebuild a generic image with the section 6 commands. Then boot and run `mkinitcpio -P` on the Pi.
- **Broken NVMe boot:** if the firmware can't load NVMe boot files, `0xf416` falls through to the SD card automatically. If the kernel starts but then panics or drops to emergency mode, disconnect the NVMe drive so SD boots, then mount the NVMe partitions and fix `cmdline.txt`/`fstab`. To restore the factory order, set `BOOT_ORDER=0xf461`.
- **Bad EEPROM config:** `rpi-eeprom-config --edit` again from any working OS, or write the rpi-imager bootloader recovery card (section 3), which resets it.
- **Return to mainline later:** if ALARM ever ships proper Pi 5 support for the mainline kernel, the switch is not a one-line `pacman -S`. `uboot-raspberrypi` and `linux-rpi` both own `/boot/kernel8.img`, so work from a host chroot with a backup: `pacman -R linux-rpi`, then `pacman -S linux-aarch64 uboot-raspberrypi`, then check that `/boot` holds U-Boot's `kernel8.img`, `boot.scr`, `Image` and `dtbs/`, and that U-Boot's `config.txt` is in place. Verify that support exists before you try it.

## 15. Sources

- ALARM Raspberry Pi platform page (install steps, default credentials): <https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-4>
- ALARM packages: <https://archlinuxarm.org/packages/aarch64/linux-rpi>, <https://archlinuxarm.org/packages/aarch64/linux-rpi-16k>
- ALARM PKGBUILDs (`core/linux-rpi`, `core/linux-rpi-16k`, `alarm/rpi-eeprom`, `alarm/raspberrypi-utils`): <https://github.com/archlinuxarm/PKGBUILDs>
- Kernel-swap method (2023 write-up): <https://kiljan.org/2023/11/24/arch-linux-arm-on-a-raspberry-pi-5-model-b/>
- ALARM forum Pi 5 how-to: <https://archlinuxarm.org/forum/viewtopic.php?p=71809>
- Raspberry Pi hardware docs (BOOT_ORDER, PCIE_PROBE, PSU_MAX_CURRENT, fan curve, `usb_max_current_enable`): <https://www.raspberrypi.com/documentation/computers/raspberry-pi.html>

## Status

Researched and written 2026-11-06, not yet run on hardware. The stock-tarball details (`fstab`, `eth.network`, `boot.txt`) were read directly from `ArchLinuxARM-rpi-aarch64-latest.tar.gz` as served on that date. When this is first done for real, add the date, board revision, kernel version, boot medium and any deviations here.
