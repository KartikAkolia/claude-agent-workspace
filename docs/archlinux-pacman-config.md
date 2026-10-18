# Arch Linux Host — `os-release` and `pacman.conf`

Snapshot of an Arch Linux machine's OS identity and pacman configuration, pasted by Kartik on 2026-10-18 from a shell prompted `[kartik@archlinux ~]$`. This machine is **`asus-vivobook`** (Kartik's laptop), now running Arch Linux with CachyOS repos under the hostname `archlinux`. It's not the `archlinux` VM (`docs/laptop-vfio-passthrough.md`, "Other VMs on this host"), which only shares the name. The match was confirmed on 2026-10-18: `/sys/class/net/*/address` shows the Wi-Fi MAC `a4:f9:33:cb:70:be` and the laptop answers at `192.168.0.13`, both matching what `docs/laptop-vfio-passthrough.md` records for `asus-vivobook`. `lspci` shows the same AMD Radeon 780M (Phoenix) and RTX 4060 Mobile.

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

Xbox controller over Bluetooth: `xpadneo-dkms` 0.10.4 from the `cachyos` repo, installed with `linux-cachyos-headers`. `dkms status` shows `hid-xpadneo/v0.10.4` installed for both `7.2.10-1-cachyos` and `6.18.57-2-lts`, so `linux-lts-headers` is present too. The module loads, with a harmless unsigned-module taint warning. A Series X|S controller (`0005:045E:0B13`) paired and got xpadneo's welcome rumble test, with rumble streaming enabled.

Steam launch option for running a game on the 4060: `prime-run gamemoderun mangohud %command%`.

Not yet verified: a game launched from Steam with `prime-run gamemoderun mangohud %command%` actually running on the 4060.

## Notable points

The machine uses CachyOS's optimized repositories on top of stock Arch. The three `znver4` repos (`cachyos-znver4`, `cachyos-core-znver4`, `cachyos-extra-znver4`) contain packages built for AMD Zen 4. They're listed ahead of `[cachyos]`, `[core]`, `[extra]`, and `[multilib]`, so for any package name found in more than one repo, the Zen 4 build wins. That's only safe on a Zen 4 CPU, or on a VM whose CPU model passes Zen 4 features through. On an older CPU, those packages fail with illegal-instruction errors.

Other non-default settings: `Color`, `ILoveCandy`, `ParallelDownloads = 5`, `DownloadUser = alpm`, `[multilib]` turned on, and both testing repos left off. `SigLevel` and `LocalFileSigLevel` are set to stock Arch's values.

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
Architecture = auto

# Pacman won't upgrade packages listed in IgnorePkg and members of IgnoreGroup
#IgnorePkg   =
#IgnoreGroup =

#NoUpgrade   =
#NoExtract   =

# Misc options
#UseSyslog
Color
ILoveCandy
#NoProgressBar
CheckSpace
#VerbosePkgLists
ParallelDownloads = 5
DownloadUser = alpm
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
