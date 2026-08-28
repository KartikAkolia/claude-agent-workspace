# Laptop Dual-Boot: Debian 12 (bookworm) Stable + Windows 11 Pro — Setup Plan

Status: **Phase 1 done, Phase 2 not yet executed** (planned 2026-08-28; Phase 1 run 2026-08-28). Kartik wants Debian Stable as a minimal, SSH-first second OS on his ASUS Vivobook M6500XV laptop, keeping Windows 11 Pro only for native Office 365 desktop apps and other Windows-only coursework software. Unlike `dell-optiplex` and the Pi 5, this box gets **no local desktop environment** — it's driven remotely, same as the other two homelab boxes are driven, just without even the optional GUI `dell-optiplex` ended up with via dwm-titus.

Full design rationale, decision table, and validation matrix live in the session plan this doc was generated from (`ai-project-manager`/`engineering-*` skills + a Plan-agent review against this repo's own homelab conventions). This file is the copy-pasteable execution runbook.

## Machine facts (gathered 2026-08-28, read-only diagnostics — see below for exact commands)

| Fact | Value |
|---|---|
| Model | ASUS Vivobook M6500XV |
| Firmware | UEFI, Secure Boot **enabled**, TPM 2.0 present/ready/enabled |
| Disk | Crucial CT1000P3PSSD8 NVMe, single disk, GPT, ~931 GB total |
| Existing partitions | EFI System (300 MB) → MSR (16 MB) → C: NTFS (930 GB, ~757 GB free) → Recovery (1 GB) |
| BitLocker | **Off** (Fully Decrypted, Protection Off, no key protectors) |
| Fast Startup (`HiberbootEnabled`) | Already `0` (off) |
| Hibernation | Already not enabled |
| RAM | ~16 GB |
| Wi-Fi | Intel Wi-Fi 6E AX210 (needs `firmware-iwlwifi`, well-supported) |

Because BitLocker, Fast Startup, and hibernation are already in the target state, Windows-side prep is much shorter than it would otherwise be — no BitLocker suspend step needed.

## Decisions (confirmed with Kartik, 2026-08-28)

- **Space split:** ~200 GB shrunk from C: for Debian, leaving Windows ~550+ GB free.
- **LUKS encryption:** Yes, on the Debian side (laptop theft/loss risk). Whether to add `dropbear-initramfs` for SSH-based remote unlock is an open follow-up, not decided yet — until then, rebooting Debian requires being physically at the laptop to enter the LUKS passphrase.
- **Recovery media:** Kartik already has Windows 11 recovery/install USB ready — this is the rollback path if the bootloader step goes wrong (see Phase 3 below).
- **Networking:** router-side DHCP reservation for the laptop's Wi-Fi MAC address, not a static IP on the laptop itself — avoids the DHCP client-id mismatch that bit `dell-optiplex` (see `docs/homelab-networkmanager-plan.md`) and suits a machine that moves between home and university networks.
- **Debian install profile:** minimal/server — `tasksel` gets only "SSH server" + "standard system utilities," no desktop environment selected.
- **Swap:** swapfile, not a swap partition (resizable later, no hibernation-sizing requirement — Windows owns sleep/hibernate on this machine).
- **Secure Boot:** left enabled, using Debian's signed shim (`shim-signed`/`grub-efi-amd64-signed`) — no need to disable it.

## Phase 0 — Diagnostics (done, 2026-08-28)

Commands run (all read-only, no changes made):

```powershell
Get-Disk | Select-Object Number, FriendlyName, PartitionStyle, Size
Get-Partition -DiskNumber 0 | Select-Object PartitionNumber, DriveLetter, Type, Size
Get-Volume -DriveLetter C | Select-Object DriveLetter, FileSystem, Size, SizeRemaining
manage-bde -status C:
Confirm-SecureBootUEFI
Get-Tpm | Format-List TpmPresent, TpmReady, TpmEnabled, ManufacturerVersion
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
Get-ComputerInfo | Select-Object CsSystemFamily, CsModel, BiosFirmwareType
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
```

Results captured in the "Machine facts" table above.

## Phase 1 — Windows-side prep (Kartik runs, elevated)

Only one real step needed, since BitLocker/Fast Startup/hibernation are already off:

```cmd
chkdsk C: /f
```

Run from an **elevated** Command Prompt. Since C: is in use, it will ask: *"Would you like to schedule this volume to be checked the next time the system restarts? (Y/N)"* — answer **Y**, then reboot once at a convenient time and let it run to completion. This was attempted automatically in this session but blocked by Claude Code's permission classifier (disk-check scheduling on the live boot volume is exactly the kind of action that should require a human's explicit go-ahead) — run it yourself when ready.

**Acceptance:** `chkdsk` reports no errors (or errors found and fixed), Windows boots normally afterward.

## Phase 2 — Partition shrink (Kartik runs)

Use Disk Management (`diskmgmt.msc`) rather than the Debian installer or a third-party tool — Windows knows how to relocate its own NTFS metadata safely:

1. Open Disk Management → right-click the C: volume → **Shrink Volume...**
2. Enter **204800** MB (= 200 GiB) as the amount to shrink.
3. Click **Shrink**. The freed space appears as **Unallocated** — leave it that way, don't format it or assign a drive letter.

If Disk Management offers noticeably less than 204800 MB as the maximum shrinkable amount (common cause: unmovable files — restore points, pagefile — pinned near the end of the volume), reduce System Restore's reserved space and/or temporarily set a smaller fixed pagefile size, then retry, rather than forcing it with a lower-level tool.

**Acceptance:** ~200 GB of unallocated space exists at the end of the disk, Windows still boots normally, no new partition was created.
**Rollback:** an interrupted/failed shrink just leaves the space unallocated or unchanged — Windows itself is untouched either way.

## Phase 3 — Debian install (Kartik runs — boots from USB)

### Media

Download the bookworm **"unofficial" netinst image with non-free firmware included**:
`https://cdimage.debian.org/cdimage/unofficial/non-free/cd-including-firmware/`
This matters specifically because the AX210 Wi-Fi card needs `firmware-iwlwifi`, and the install profile has no desktop GUI to fall back on if Wi-Fi doesn't come up during install. Verify the image checksum/signature before writing it to USB (Rufus, or `dd`/balenaEtcher).

### tasksel

At "Software selection": deselect every desktop-environment checkbox. Select only **SSH server** and **standard system utilities**.

### Partitioning — manual, not guided

1. The installer will detect the existing **EFI System Partition** — select it, mount as `/boot/efi`, and **leave "format this partition" unchecked**. This is the one action in the entire plan capable of actually breaking Windows boot rather than just requiring a fix — double-check this before continuing.
2. In the ~200 GB of unallocated space:
   - Create a partition, mark it as a **physical volume for encryption** (LUKS), and set up **LVM** inside it: root `/` (ext4) and optionally a separate `/home`. `/boot` stays **outside** the LUKS volume, unencrypted, since GRUB needs to read it before a passphrase is entered.
   - Skip creating a swap partition — a swapfile gets created post-install instead.
3. Before confirming, review the partition summary screen and verify it shows **no changes** to the Windows/ESP/MSR/Recovery partitions.

### Post-install: swapfile

```bash
sudo fallocate -l 4G /swapfile   # size to taste, ~16GB RAM so 4-8G is plenty for a server profile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Bootloader — the bookworm os-prober gotcha

Debian 12 ships `GRUB_DISABLE_OS_PROBER=true` in `/etc/default/grub` **by default**. Left as-is, `update-grub` will silently **not** detect Windows even though it's on the same disk — the most common reason people think dual-boot "failed." Fix explicitly:

```bash
sudo sed -i 's/^GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
sudo update-grub
grep -i "windows boot manager" /boot/grub/grub.cfg   # confirm before rebooting — don't just trust the command succeeded
```

GRUB installs to the shared ESP using the signed shim path (`shim-signed`/`grub-efi-amd64-signed`, pulled in automatically since Secure Boot is enabled) — no need to disable Secure Boot.

### Rollback plan for this phase (stated now, before it's needed)

`grub-install` writes to `\EFI\debian\` on the ESP and does **not** touch or overwrite `\EFI\Microsoft\Boot\bootmgfw.efi`. Right after install completes, capture a known-good baseline:

```bash
efibootmgr -v
```

- **Likely failure — NVRAM boot order changed, Windows entry still exists:** use the firmware boot menu (F2/F12/Esc at power-on, check ASUS's key for this model) to pick "Windows Boot Manager" once. Fix permanently with `efibootmgr -o <order>` from Debian, or `bcdedit /set {fwbootmgr} displayorder` from Windows.
- **Unlikely failure — Windows Boot Manager's NVRAM entry or ESP boot files are gone:** boot the Windows 11 recovery USB → Troubleshoot → Advanced options → Command Prompt:

  ```cmd
  diskpart
  list vol                      # identify the ESP: FAT32, ~300 MB
  sel vol N
  assign letter=S
  exit
  bootrec /fixboot
  bcdboot C:\Windows /s S: /f UEFI
  ```

  Run `bootrec /rebuildbcd` first if the BCD store itself looks corrupt. This restores Windows without touching C: data or needing to remove Debian's entry.

**Acceptance:** first reboot reaches a GRUB menu listing both "Debian GNU/Linux" and "Windows Boot Manager"; both boot successfully.

## Phase 4 — Post-install SSH/firewall/network baseline

1. **SSH keys** — same pattern as `pi-homelab/raspberry-pi-ssh-setup.md`: append the existing shared `~/.ssh/id_ed25519.pub` to this laptop's `~/.ssh/authorized_keys` (do this over the physical console, no need for password-over-network since the laptop is right there), verify key login works, **then** disable password auth in `sshd_config` (`sudo sshd -t` to validate before restarting, back up the original config with a timestamp suffix first).
2. **`~/.ssh/config` alias** — add a `Host` stanza once the DHCP reservation is set on the router and the laptop's stable home-network IP is known.
3. **Firewall (nftables)** — replicate the `dell-optiplex`/Minecraft-host default-drop pattern: loopback, established/related, ICMP, and SSH (22) allowed; everything else dropped. Add new allows *before* standing up any future service, not after discovering it's unreachable.
4. **Networking** — set the DHCP reservation on the router for the laptop's Wi-Fi MAC address (find it via `ip link show` on Debian or Device Manager on Windows). No static IP configuration needed on the laptop itself.
5. **Sleep/suspend** — deliberately leave Debian's default suspend-on-lid-close behavior alone (do **not** mask the sleep targets the way `dell-optiplex` does) — this is a laptop meant to still suspend normally, not an always-on box.
6. **LUKS remote-unlock (optional, not decided yet)** — if the "must be physically present to enter the LUKS passphrase on reboot" friction becomes a problem, `dropbear-initramfs` can be added later to allow SSH-based unlock at boot.

Any generated credential (e.g. an initial user password) gets written to a file on the laptop for Kartik to retrieve and delete himself — Claude Code's classifier blocks printing generated secrets into chat, same pattern as the Vaultwarden Pi's `.new_admin_token`.

## Phase 5 — Validation matrix

| Check | Method | Pass criteria |
|---|---|---|
| Windows boots | Select from GRUB menu | Reaches desktop normally |
| Office 365 desktop apps / coursework software | Manual launch | Opens and works offline as before |
| Debian boots | Select from GRUB menu | Reaches login prompt (no local GUI) |
| LUKS unlock | Boot Debian | Prompts for passphrase before continuing |
| SSH reachable after cold boot | `ssh <alias> "uptime"` from another host | Connects once the LUKS passphrase has been entered locally |
| SSH survives reboot | `ssh <alias> "sudo reboot"`, reconnect | Reconnects on the new boot (after LUKS unlock), same host key |
| Firewall state | `nft list ruleset` over SSH | Only loopback/established/ICMP/SSH allowed |
| GRUB survives a Windows Update | Reboot into Debian after a normal Windows Update | GRUB menu still present, unmodified — Windows Updates occasionally rewrite `bootmgfw.efi`/NVRAM order |
| os-prober fix persisted | `grep GRUB_DISABLE_OS_PROBER /etc/default/grub` after any future `update-grub` | Still `false`, Windows entry still in `grub.cfg` |

## What actually happened

- **Phase 1 (2026-08-28):** `chkdsk C: /f` run from an elevated Command Prompt as planned — no deviations, reported no errors. Windows boots normally. Phase 2 (partition shrink) is next.

*(append further entries here as Phases 2–4 are executed, including any deviations from this plan — matching the convention in `docs/homelab-networkmanager-plan.md`)*

## Sources

- [Debian Installation Guide — Partitioning for Dual-Boot Systems](https://www.debian.org/releases/stable/amd64/apbs01.en.html)
- [Debian Wiki — UEFI (Secure Boot, shim-signed, os-prober)](https://wiki.debian.org/UEFI)
- [Debian Wiki — GRUB (os-prober disabled by default since bookworm)](https://wiki.debian.org/Grub)
- [Microsoft Learn — BitLocker `manage-bde` reference](https://learn.microsoft.com/windows-server/administration/windows-commands/manage-bde)
- [Microsoft Learn — `Resize-Partition` / Disk Management shrink behavior](https://learn.microsoft.com/powershell/module/storage/resize-partition)
- `docs/homelab-networkmanager-plan.md` (this repo — DHCP client-id precedent behind the DHCP-reservation-over-static decision)
- `pi-homelab/raspberry-pi-ssh-setup.md` (this repo — SSH key rollout / secrets-to-file pattern)
