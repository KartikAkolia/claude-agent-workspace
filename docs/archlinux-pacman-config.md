# Arch Linux Host — `os-release` and `pacman.conf`

Snapshot of an Arch Linux machine's OS identity and pacman configuration, pasted by Kartik on 2026-10-18 from a shell prompted `[kartik@archlinux ~]$`. This machine is **`asus-vivobook`** (Kartik's laptop), now running Arch Linux with CachyOS repos under the hostname `archlinux`. It's not the `archlinux` VM (`docs/laptop-vfio-passthrough.md`, "Other VMs on this host"), which only shares the name. The match was confirmed on 2026-10-18: `/sys/class/net/*/address` shows the Wi-Fi MAC `a4:f9:33:cb:70:be` and the laptop answers at `192.168.0.13`, both matching what `docs/laptop-vfio-passthrough.md` records for `asus-vivobook`. `lspci` shows the same AMD Radeon 780M (Phoenix) and RTX 4060 Mobile. fastfetch output (2026-10-18) gives the model as an ASUS Vivobook M6500XV with a Ryzen 9 7940HS (16 threads), 14.84 GiB of RAM, a 1920x1080 144 Hz panel, and swap disabled.

The RTX 4060 is bound to `nvidia`, not `vfio-pci`, which fits the passthrough revert recorded in that doc on 2026-09-07. On 2026-09-17 the laptop ran `nvidia-open-dkms` 615.71.09 on `6.18.52-1-lts` with `kwin_wayland`. On 2026-10-18 it had no desktop installed and runs `7.2.10-1-cachyos` with `linux-cachyos-nvidia-open` 615.78.08. That suggests a reinstall or a large cleanup in between. Checked 2026-10-18: `nvidia-open-dkms` is gone, but `linux-lts` 6.18.57-2 is still installed, with no NVIDIA module for it. Booting it gives a working AMD desktop with no driver for the RTX 4060. It's kept as a rescue kernel, and `linux-cachyos` is the daily kernel.

## Gaming setup (2026-10-18)

Kernel `7.2.10-1-cachyos`. Installed with `sudo pacman -Syu --needed vulkan-radeon lib32-vulkan-radeon linux-cachyos-nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime cachyos-gaming-meta cachyos-gaming-applications gamemode lib32-gamemode proton-cachyos ttf-liberation vulkan-tools`. `proton-cachyos` resolved to `proton-cachyos-native`. The machine had no desktop, so a minimal KDE Plasma was added: `plasma-desktop sddm konsole dolphin powerdevil kscreen plasma-pa plasma-nm xdg-desktop-portal-kde`, with `sddm` enabled.

Verified from Kartik's pasted output, not run by Claude:

- **Packages:** `pacman -Q` lists all of them, `pacman -Qk` reports no missing files, and `pacman -Dk` reports no database errors.
- **NVIDIA:** the RTX 4060 is bound to `nvidia`, not `vfio-pci`, and `nvidia-smi` shows driver 615.78.08.
- **AMD:** the 780M is on `amdgpu`, firmware loaded cleanly, and `dmesg` shows no `amdgpu` errors. Mesa is 26.2.4.
- **Graphics in a Plasma session:** `glxinfo` names the Radeon 780M (`radeonsi`), and `prime-run glxinfo` names the RTX 4060.
- **gamemode:** `gamemoded -t` passes once Kartik is in the `gamemode` group.

Bluetooth, added later the same day: `sudo pacman -S --needed bluez bluez-utils bluedevil pipewire-audio pipewire-pulse wireplumber`, then `sudo systemctl enable --now bluetooth`. `systemctl is-active bluetooth` reports `active`, and `bluetoothctl show` reports the adapter as `archlinux` with `Powered: yes`. No devices have been paired yet.

Xbox controller over Bluetooth: `xpadneo-dkms` 0.10.4 from the `cachyos` repo, installed with `linux-cachyos-headers`. `dkms status` shows `hid-xpadneo/v0.10.4` installed for both `7.2.10-1-cachyos` and `6.18.57-2-lts`, so `linux-lts-headers` is present too. The module loads, with a harmless unsigned-module taint warning. A Series X|S controller (`0005:045E:0B13`) paired, and xpadneo's welcome rumble test ran with rumble streaming enabled. Kartik confirmed the controller rumbled.

Brave (`brave-origin-bin` 1.97.59, Chromium 155) showed YouTube with sound but no picture. There were two layers to it.

1. `/etc/environment` set `LIBVA_DRIVER_NAME=nvidia`, which forced NVIDIA's VA-API driver even though Brave renders on the AMD 780M. That line was removed (backup at `/etc/environment.bak`), so Mesa now picks `radeonsi` on its own. `vainfo` shows VP9 and AV1 decode on both GPUs. `MOZ_DISABLE_RDD_SANDBOX=1` was a Firefox-only leftover from the same NVIDIA VA-API setup. It was also removed (backup at `/etc/environment.bak2`), and after relogging it's confirmed `unset`. `/etc/environment` now contains only comments.
2. Even with decoding on the AMD chip, Brave's default renderer (Wayland, ANGLE on OpenGL) failed to import decoded frames, logging `eglCreateImage failed with 0x00003009` (`EGL_BAD_MATCH`). `--disable-accelerated-video-decode` played fine, which pinned the fault on the hardware-decode handover. Vulkan isn't allowed under `--ozone-platform=wayland`; Chromium logs that the two aren't compatible.

Working fix, verified 2026-10-18 by Kartik (playback works, `brave://gpu` shows Video Decode hardware accelerated): `~/.config/brave-origin-flags.conf`, the file `/usr/bin/brave-origin` reads. At that point the file contained `--ozone-platform=x11`, `--use-angle=vulkan` and `--enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan`, one per line. The trade-off was that Brave ran under XWayland. The live file now holds the Wayland trial below.

Wayland-native trial (2026-10-25, partly verified): the flags file now contains `--ozone-platform=wayland` and `--disable-features=AcceleratedVideoDecodeLinuxZeroCopyGL`. The Vulkan flags were dropped because Chromium rejects Vulkan under Wayland. The working X11 version is saved as `~/.config/brave-origin-flags.conf.x11.bak`. To revert, run `cp ~/.config/brave-origin-flags.conf.x11.bak ~/.config/brave-origin-flags.conf` and restart Brave. A `brave://gpu` report saved at 08:45 on 2026-10-25, about 35 seconds after launch, confirms that both flags are on the command line. It shows Ozone platform `wayland`, Display type `ANGLE_OPENGL` on the 780M (radeonsi), Video Decode "Hardware accelerated", and VA-API decode profiles for H.264, VP9, HEVC and AV1. Its log has no `eglCreateImage` error, only a sandbox warning. A `brave://media-internals` dump saved at 08:47 shows every YouTube player that had video using `VaapiVideoDecoder` with `kIsPlatformVideoDecoder: true`, for AV1 at 640x360, 1280x720 and 1920x1080. One 1080p player was still in `kPlaying` after about 89 seconds. The dump contains no pipeline errors and no fallback to `Dav1dVideoDecoder`; the only "Cannot select" lines are normal decoder probing. Not yet confirmed: a `brave://gpu` log captured after playback still has no `eglCreateImage` error, since the 08:45 report came before the video played.

Network (2026-10-18): Wi-Fi `wlp2s0` (Intel AX210, `iwlwifi`) is on NetworkManager profile `VM2411078` at `192.168.0.13/24`, gateway `192.168.0.1`. That profile was changed with `nmcli connection modify "VM2411078" ipv4.dns "1.1.1.1 1.0.0.1" ipv4.ignore-auto-dns yes ipv6.method disabled` and applied with `nmcli device reapply wlp2s0`. Verified: `IP4.DNS` shows only `1.1.1.1` and `1.0.0.1` (previously Virgin Media's `194.168.4.100` and `194.168.8.100`), `/etc/resolv.conf` matches, and there's no IPv6 address. This applies to that profile only, not to other networks or system-wide. It also bypasses the AdGuardHome Pi at `192.168.0.166`.

Desktop portals, checked 2026-10-18 from a Konsole window inside Plasma: `xdg-desktop-portal` 1.22.1, `xdg-desktop-portal-kde` 6.8.0 and `xdg-desktop-portal-gtk` 1.15.3 are installed. The registered back-ends are `gtk`, `kde`, `kwallet` and `plasmanotify`, and `kde-portals.conf` is present. The `xdg-desktop-portal` and `plasma-xdg-desktop-portal-kde` user services are `active`, and the FileChooser portal answers with version `u 4`.

GParted (2026-10-18): installed with `sudo pacman -S --needed gparted btrfs-progs dosfstools exfatprogs f2fs-tools gpart jfsutils mtools nilfs-utils ntfsprogs udftools xfsprogs polkit polkit-kde-agent xorg-xhost`. That's GParted's own `pacman -Si` optional-deps list, minus `bcachefs-tools`, plus Plasma's polkit agent. `pacman -Q` confirms `gparted` 1.8.1-2.2, `xorg-xhost` 1.0.10-1.2, `polkit-kde-agent` 6.8.0-1.1 and `ntfsprogs` 2026.9.28-1.1. Not yet checked: the rest of the filesystem tools individually, and GParted's View → File System Support grid. The older `docs/gparted-root-theme-fix.md` describes the pre-reinstall setup on this laptop.

topgrade (2026-10-18): installed. `~/.config/topgrade.toml` was created fresh with only `[misc]` and `disable = ["firmware"]`. The `firmware` step is topgrade's `fwupd` step, and the step name comes from topgrade's docs. `topgrade --dry-run` shows no firmware or fwupd step.

Virtualisation (2026-10-18): before setup, the hardware was ready (`lscpu` showed AMD-V, `/dev/kvm` existed, `kvm_amd` was loaded) but none of the virtualisation packages were installed. The `libvirt` group already existed and Kartik was already in it. Installed: `qemu-desktop libvirt virt-manager virt-viewer edk2-ovmf swtpm dnsmasq dmidecode`. Then `systemctl enable --now libvirtd.service`, `usermod -aG libvirt`, and `net-start` plus `net-autostart` for the `default` network. `virt-host-validate qemu` passes everything, including SVM, `/dev/kvm`, vhost-net, tun and IOMMU (IVRS). It warns on two expected items: the cgroup `devices` controller, because the check ran unprivileged, and SEV/TDX, which laptop CPUs don't have. `virsh -c qemu:///system net-list --all` shows `default` active, autostart and persistent. `LIBVIRT_DEFAULT_URI=qemu:///system` is set in `~/.config/environment.d/libvirt.conf` for the Plasma session. SSH bash shells don't read that file and still showed `qemu:///session`. That line was added to `~/.bashrc`, and plain `virsh uri` over SSH now prints `qemu:///system`. Networking is NAT only (`192.168.122.0/24`), because a Wi-Fi interface can't be bridged. The old `br0` used a USB Ethernet dongle. Whether any old VM definitions such as `win11` and `archlinux` survived the reinstall hasn't been checked.

GTK Nordic theme (2026-10-18): the AUR `nordic-theme` package is installed system-wide at `/usr/share/themes/Nordic` (no variant folders), alongside `papirus-icon-theme`. Plasma's GTK settings button didn't appear, so the config was written by hand:

- **GTK3:** `~/.config/gtk-3.0/settings.ini` was edited in place (backup at `settings.ini.bak`) to `gtk-theme-name=Nordic`, `gtk-icon-theme-name=Papirus-Dark` and `gtk-application-prefer-dark-theme=1`.
- **GTK4:** `~/.config/gtk-4.0/settings.ini` was created with the same three keys.
- **libadwaita:** `~/.config/gtk-4.0/gtk.css` and `gtk-dark.css` are symlinked to Nordic's `gtk-4.0/` files. Nordic's GTK4 CSS loads images from `../assets/`, which resolves from `~/.config/gtk-4.0/` to `~/.config/assets`, so `~/.config/assets` is a symlink to `/usr/share/themes/Nordic/assets`. There's no `assets` link inside `gtk-4.0/`.
- **gsettings:** `gtk-theme 'Nordic'`, `icon-theme 'Papirus-Dark'` and `color-scheme 'prefer-dark'` were set, and `gsettings get` confirms `'Nordic'`. Over SSH this needs `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus`; otherwise gsettings falls back to a memory backend and the changes are lost.
- **Root GTK apps (GParted):** `/root/.config/gtk-3.0/settings.ini` is a symlink to Kartik's file, the same approach as `docs/gparted-root-theme-fix.md`.

Persistence was checked after a logout and login. Both `settings.ini` files still read `Nordic` and `Papirus-Dark`, and `gsettings` still reports `'Nordic'`. `kde-gtk-config` 6.8.0-1.1 is installed. The keys in `gtk-3.0/settings.ini` came back reordered, which suggests it rewrote the file at login and kept the values. Plasma's GTK settings button was missing even though the package is installed; the cause wasn't investigated. Not yet verified: a visual check in an actual GTK app.

Qt Nordic theme via Kvantum (2026-10-18): installed `kvantum` and `kvantum-qt5`, plus `kvantum-theme-nordic-git` and `nordic-kde-git` from the `cachyos` repo. Neither declares a conflict and there were no file conflicts. `nordic-theme`, the GTK theme, is a separate package from the AUR, installed with `yay` (`paru` isn't installed). Available Kvantum variants: `Nordic`, `Nordic-Darker`, `Nordic-Darker-Solid`, `Nordic-Solid`, `Nordic-bluish` and `Nordic-bluish-solid`. Available colour schemes: `Nordic`, `NordicDarker` and `nordicbluish`.

Applied: `~/.config/Kvantum/kvantum.kvconfig` was written by hand with `[General]` and `theme=Nordic`, `kdeglobals [KDE] widgetStyle=kvantum` was set, and the colour scheme was set to `Nordic` (`kreadconfig6` confirms both). Over SSH, Qt GUI tools such as `kvantummanager` and `plasma-apply-colorscheme` abort because they can't open a display. Qt's error message blames a missing `xcb-cursor0`, but that's misleading: `xcb-util-cursor` was already installed. The workaround is `QT_QPA_PLATFORM=offscreen` together with the `DBUS_SESSION_BUS_ADDRESS` export. The colour scheme was applied as BreezeDark first, then Nordic, so the re-apply was forced. `nordic-kde-git` is labelled Plasma 5; its Plasma desktop theme and window decorations were deliberately not applied.

SDDM login screen: `sddm-nordic-theme-git` installs the `Nordic`, `Nordic-bluish` and `Nordic-darker` themes. None of them sets `QtVersion=6`, so SDDM runs them with the Qt5 `sddm-greeter`, and both greeters are installed. They don't work, though. `sddm-greeter --test-mode` fails with `Main.qml:28:1: module "org.kde.plasma.extras" is not installed`, because the Qt5 Plasma framework isn't present and `plasma-framework5` isn't in the repos. The workaround is the Qt6 `breeze` SDDM theme with Nordic's background. `/usr/share/sddm/themes/breeze/theme.conf.user` sets `[General] background=` to the Nordic theme's `assets/bg.jpg`, and `/etc/sddm.conf.d/theme.conf` sets `[Theme] Current=breeze`. Kartik confirmed on 2026-10-18 that the preview and the real login screen show the Nordic background. The background image was then copied to `/usr/share/sddm/themes/breeze/nordic-bg.jpg`, and `theme.conf.user` now points at that copy, so the login screen no longer depends on `sddm-nordic-theme-git` being installed. `pacman -Qo` confirms no package owns `theme.conf.user`, so Breeze updates leave it alone. The copied `nordic-bg.jpg` isn't owned by a package either. The background hasn't been rechecked on the real login screen since the path changed. Recovery from a broken greeter: Ctrl+Alt+F3 or SSH, then `sudo rm /etc/sddm.conf.d/theme.conf` and `sudo systemctl restart sddm`.

Steam launch option for running a game on the 4060: `prime-run gamemoderun mangohud %command%`.

Not yet verified: a game launched from Steam with `prime-run gamemoderun mangohud %command%` actually running on the 4060.

Steam launch-option recommendations (2026-10-21), suggested by Claude and not yet applied or tested in a game. Both displays (eDP-1 at 144 Hz, external DP-1 at 180 Hz) are wired to the 780M, so `prime-run` is needed and every frame is copied back across PCIe. Only the HDMI port (`card0-HDMI-A-1`) is wired to the 4060, so gaming on an external monitor over HDMI skips that copy; the port's HDMI version hasn't been checked. The default Proton is `proton-cachyos-slr`, and the variable names below were checked against its own `proton` script. NTSYNC needs no flag: `/dev/ntsync` exists and Proton uses it automatically.

Update after the 2026-10-21 reboot: Kartik moved the external monitor from DisplayPort to HDMI. `kscreen-doctor -o` shows `HDMI-A-1` enabled at 1920x1080@180 and `eDP-1` disabled, and `card0` (which owns `HDMI-A-1`) is bound to the `nvidia` driver at `0000:01:00.0`. Reaching 180 Hz at 1080p over HDMI means the port has at least HDMI 2.0 bandwidth, and the 180 Hz entry in the frame-cap suggestion below still applies. Two consequences remain untested: whether games still need `prime-run` on this layout, and how much battery life drops now that the 4060 stays awake to drive the display. VRR is `Never` on `HDMI-A-1`.

- **Suggested global line:** `PROTON_DLSS_UPGRADE=1 __GL_SHADER_DISK_CACHE_SIZE=12000000000 prime-run gamemoderun mangohud %command%`. The first variable swaps in the latest DLSS in games that ship it (`PROTON_DLSS_INDICATOR=1` shows an overlay confirming it). The second raises NVIDIA's shader cache to about 12 GB to cut shader-compile stutter.
- **Per game, not global:** `PROTON_ENABLE_WAYLAND=1` (native Wayland: lower latency and HDR, but the Steam overlay and some launchers can break), `PROTON_DXVK_LOWLATENCY=1` for DX9–11 or `PROTON_VKD3D_LOWLATENCY=1` for DX12 (low-latency DXVK and VKD3D forks, for competitive games), and `PROTON_LOG=1` for debugging.
- **Frame cap:** there's no `~/.config/MangoHud/MangoHud.conf` yet. Suggested contents: `fps_limit=141,177,0`, which is just under each display's refresh rate, with Shift+F1 cycling through them.
- **Optional:** `scx_lavd` (from `scx-scheds`) is installed but not running. Try `sudo scx_lavd --performance` only if a game shows CPU-side stutter; the CachyOS kernel's default scheduler is already tuned.

Dynamic Boost and zram (2026-10-21), both set up by Kartik and inspected by Claude. `nvidia-powerd.service` is enabled and active, and `nvidia-smi` reports a 75 W power limit (35 W default) instead of `N/A`. `zram-generator` 1.2.1 is installed with `/etc/systemd/zram-generator.conf` setting `[zram0]`, `zram-size = ram / 2` and `compression-algorithm = zstd`. A dry run of the generator produced `dev-zram0.swap` at priority 100, and swap only appears after a reboot. Verified after the 2026-10-21 09:45 reboot (closed item 33, now in `docs/archival.md`): `/dev/zram0` is active as 7.4G `zstd` swap at priority 100, zswap reads `N`, and `nvidia-powerd` is active. At idle (P8, 2 W draw) `nvidia-smi` showed a 65 W current limit against a 75 W maximum. Dynamic Boost moves the current limit, so 65 W at idle doesn't show a fault, but nobody has checked yet whether it reaches 75 W under GPU load. `zswap.enabled=0` was then added to the GRUB command line so pages aren't compressed twice; it applies from the next boot. GRUB's default entry (`GRUB_DEFAULT=0`) boots `linux-lts`, which has no NVIDIA module; only the CachyOS kernel does, so `GRUB_DEFAULT` was changed to the CachyOS entry under "Advanced options" (`gnulinux-advanced-…>gnulinux-linux-cachyos-advanced-…`) and `grub.cfg` regenerated. `vm.swappiness` is already 100 and `vm.page-cluster` 0, which suit zram.

## Locally built software

The XP-Pen driver (`xppen-tablet`, a local package from `scripts/xppen-tablet/`) was also removed on 2026-10-31, by Kartik at 09:14. WordCraft, PdfCraft and DeckCraft were built from source as local pacman packages, kept current by a root `craft-update.timer`. All three were uninstalled on 2026-10-31, and the timer, its script, the user data and this repo's PKGBUILDs and docs were removed the same day (see the 2026-10-31 entry in `docs/handoff.md`). Git history has the old craft-update and per-app build docs. With them gone, `xdg-mime query default` gives `brave-origin.desktop` for `.pdf` and no default for `.docx` or `.pptx` (checked 2026-10-31).

## Notable points

The machine uses CachyOS's optimized repositories on top of stock Arch. The three `znver4` repos (`cachyos-znver4`, `cachyos-core-znver4`, `cachyos-extra-znver4`) contain packages built for AMD Zen 4. They're listed ahead of `[cachyos]`, `[core]`, `[extra]`, and `[multilib]`, so for any package name found in more than one repo, the Zen 4 build wins. That's only safe on a Zen 4 CPU, or on a VM whose CPU model passes Zen 4 features through. On an older CPU, those packages fail with illegal-instruction errors.

Other non-default settings: `Architecture = x86_64 x86_64_v4` (needed for the CachyOS builds), `IgnorePkg = kwin kscreen libkscreen` (the Plasma flicker hold, see `docs/handoff.md`; drop it before taking Plasma 6.8.2 as a whole, or a partial upgrade can block on dependencies), `Color`, `ILoveCandy`, `ParallelDownloads = 5`, `DownloadUser = alpm`, `[multilib]` turned on, and both testing repos left off. `SigLevel` and `LocalFileSigLevel` are set to stock Arch's values.

Not captured here: what's inside `/etc/pacman.d/cachyos-v4-mirrorlist` and `/etc/pacman.d/cachyos-mirrorlist`, and whether the CachyOS keyring is installed (`pacman -Q cachyos-keyring`).

## `/etc/os-release`

```text
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://archlinux.org/"
DOCUMENTATION_URL="https://wiki.archlinux.org/"
SUPPORT_URL="https://bbs.archlinux.org/"
BUG_REPORT_URL="https://gitlab.archlinux.org/groups/archlinux/-/issues"
PRIVACY_POLICY_URL="https://terms.archlinux.org/docs/privacy-policy/"
LOGO=archlinux-logo
```

## `/etc/pacman.conf` (verbatim)

Copied from the live file on 2026-10-31, after the Mesa and firmware holds were dropped.

```ini
#
# /etc/pacman.conf
#
# See the pacman.conf(5) manpage for option and repository directives

#
# GENERAL OPTIONS
#
[options]
# The following paths are commented out with their default values listed.
# If you wish to use different paths, uncomment and update the paths.
#RootDir     = /
#DBPath      = /var/lib/pacman/
#CacheDir    = /var/cache/pacman/pkg/
#LogFile     = /var/log/pacman.log
#GPGDir      = /etc/pacman.d/gnupg/
#HookDir     = /etc/pacman.d/hooks/
HoldPkg     = pacman glibc
#XferCommand = /usr/bin/curl -L -C - -f -o %o %u
#XferCommand = /usr/bin/wget --passive-ftp -c -O %o %u
#CleanMethod = KeepInstalled
Architecture = x86_64 x86_64_v4

# Pacman won't upgrade packages listed in IgnorePkg and members of IgnoreGroup
IgnorePkg   = kwin kscreen libkscreen
#IgnoreGroup =

#NoUpgrade   =
#NoExtract   =

# Misc options
#UseSyslog
Color
#NoProgressBar
#PrettyProgressBar
ILoveCandy
CheckSpace
#VerbosePkgLists
ParallelDownloads = 5
DownloadUser = alpm
#DisableSandbox
#DisableSandboxFilesystem
#DisableSandboxSyscalls

# By default, pacman accepts packages signed by keys that its local keyring
# trusts (see pacman-key and its man page), as well as unsigned packages.
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
#RemoteFileSigLevel = Required

# NOTE: You must run `pacman-key --init` before first using pacman; the local
# keyring can then be populated with the keys of all official Arch Linux
# packagers with `pacman-key --populate archlinux`.

#
# REPOSITORIES
#   - can be defined here or included from another file
#   - pacman will search repositories in the order defined here
#   - local/custom mirrors can be added here or in separate files
#   - repositories listed first will take precedence when packages
#     have identical names, regardless of version number
#   - URLs will have $repo replaced by the name of the current repo
#   - URLs will have $arch replaced by the name of the architecture
#
# Repository entries are of the format:
#       [repo-name]
#       Server = ServerName
#       Include = IncludePath
#
# The header [repo-name] is crucial - it must be present and
# uncommented to enable the repo.
#

# The testing repositories are disabled by default. To enable, uncomment the
# repo name header and Include lines. You can add preferred servers immediately
# after the header, and they will be used before the default mirrors.

#[core-testing]
#Include = /etc/pacman.d/mirrorlist

# CachyOS repositories (znver4) - must stay above [core]
[cachyos-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-core-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-extra-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

#[extra-testing]
#Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

# If you want to run 32 bit applications on your x86_64 system,
# enable the multilib repositories as required here.

#[multilib-testing]
#Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# An example of a custom package repository.  See the pacman manpage for
# tips on creating your own repositories.
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs
```
