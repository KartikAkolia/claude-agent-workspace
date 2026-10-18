# `archlinux` Laptop Gaming Setup — Session Log (2026-10-18)

A chronological record of the Claude Code session that set up Steam and gaming on the `archlinux` laptop. Each step gives Kartik's request, what Claude recommended, and the output Kartik pasted back. Claude was running on macOS and had no shell on the laptop. Kartik ran every command himself, and the results below are from his pasted output. The end state lives in `docs/archlinux-pacman-config.md`. This file records how it got there.

The raw transcript is kept outside the repo, in Claude Code's own store: `~/.claude/projects/-Users-kartik-claude-agent-workspace-master/5fb10a8d-8440-4a9f-a144-164133374b3d.jsonl`. It's deliberately not committed, because it contains session context that shouldn't be in git.

## 1. Store the host config

Kartik pasted `/etc/os-release` (Arch Linux, rolling) and `/etc/pacman.conf`, and asked for it to be stored. Saved verbatim to `docs/archlinux-pacman-config.md`. The file notes that the CachyOS `znver4` repos (`cachyos-znver4`, `cachyos-core-znver4`, `cachyos-extra-znver4`) are listed ahead of `[cachyos]`, `[core]`, `[extra]` and `[multilib]`, which is only safe on a Zen 4 CPU. At that point it wasn't known which machine `kartik@archlinux` was. It might have been the `archlinux` VM on `asus-vivobook`.

## 2. Gaming packages

Kartik asked for the gaming dependencies for Steam and related tools. A web search confirmed the CachyOS meta-packages:

- `cachyos-gaming-meta`: gaming libraries, including the 32-bit ones.
- `cachyos-gaming-applications`: Steam, Heroic, Lutris, Faugus, Gamescope, MangoHud and GOverlay, per the CachyOS wiki.

Claude added a GPU driver choice for AMD or NVIDIA, plus `gamemode`, `proton-cachyos` and `ttf-liberation`. It warned that the `archlinux` VM had no GPU passed through, and that forum users had reported the meta-package failing to install in early 2026 because some `lib32-*` packages had been removed.

## 3. Choosing the `lib32-vulkan-driver` provider

pacman offered 32 providers. Before the GPU was known, Claude gave a table matching each GPU to its pick, said to avoid `lib32-mesa-git`, and to prefer the CachyOS-repo copies so they match the repo order. Kartik then pasted `lspci`. It showed real hardware with an AMD Phoenix1 iGPU (Radeon 780M) and an NVIDIA AD107M (RTX 4060 Mobile), so it's a hybrid laptop and not the VM. The pick was **17, `lib32-vulkan-radeon`**, with the NVIDIA packages installed alongside it.

## 4. Final install command

```sh
sudo pacman -Syu --needed \
  vulkan-radeon lib32-vulkan-radeon \
  linux-cachyos-nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime \
  cachyos-gaming-meta cachyos-gaming-applications \
  gamemode lib32-gamemode proton-cachyos ttf-liberation vulkan-tools
```

`linux-cachyos-nvidia-open` was chosen because the kernel is a CachyOS one. On stock Arch it would have been `nvidia-open`. After the reboot, `uname -r` returned `7.2.10-1-cachyos`, which confirmed the right module.

## 5. GPU verification after the reboot

- **`lspci -k -s 01:00.0`:** `Kernel driver in use: nvidia`, so the card isn't bound to `vfio-pci` for passthrough.
- **`nvidia-smi`:** RTX 4060 Laptop GPU on driver 615.78.08, idling at P3 and 9 W. Claude offered to set up NVIDIA runtime power management if battery life matters.
- **`vulkaninfo --summary`:** both GPUs listed, the AMD one through `radv` and the 4060 through `NVIDIA`. The `'DISPLAY' environment variable not set` warning came from running outside a graphical session.

## 6. Package integrity

- **`command -v`:** finds `steam`, `lutris`, `heroic`, `gamescope`, `mangohud`, `gamemoderun` and `prime-run`.
- **`gamemoded -t`:** first failed with `Governor was not set to performance (was actually powersave)`. Claude advised joining the `gamemode` group. `groups` then showed `kartik gamemode wheel libvirt`, and the test passed.
- **`pacman -Q`:** all 13 packages installed. `proton-cachyos` resolved to `proton-cachyos-native` 1:11.0.20261014-2. `nvidia-utils` (615.78.08-2) and `lib32-nvidia-utils` (615.78.08-1) are on the same upstream version, and the NVIDIA module is 7.2.10-1, matching the kernel.
- **`pacman -Qk … | grep -v ' 0 missing files'`:** printed nothing, so no files are missing.
- **`pacman -Dk`:** `No database errors have been found!`

## 7. AMD driver check

- **Driver:** `lspci -k -s 64:00.0` shows `amdgpu`, and the module is loaded.
- **Errors:** `dmesg` shows no `amdgpu` errors.
- **Firmware:** DMUB 0x08006200, VCN ENC 1.24 / DEC 9 and SMU 76.65.0 all loaded.
- **Versions:** `linux-firmware-amdgpu` 1:20260916-1, `mesa` and `lib32-mesa` 3:26.2.4-1.

`glxinfo` failed with `unable to open display`. The `amdgpu` use count of `0` was consistent with no graphical session running.

## 8. Finding there was no desktop

A diagnostic showed `SSH=192.168.0.154 … 192.168.0.13 22 TYPE=tty`. Kartik was connected over SSH to the laptop at `192.168.0.13`. There was no `display-manager.service`, and the only graphical package was `xorg-xwayland`. A wider search matched only `libva-nvidia-driver`, a false positive on "river", so no compositor was installed.

`eglinfo -B -p surfaceless` reported the RTX 4060, because the graphics library loader tries NVIDIA's EGL driver before Mesa's when no display is involved. That's expected and not a fault. The Mesa-forced variant was suggested but not run.

## 9. Minimal Plasma desktop

Claude recommended KDE Plasma on Wayland. Kartik wanted only the core of Plasma, not `plasma-meta`. NetworkManager is active, so `plasma-nm` was included:

```sh
sudo pacman -S --needed plasma-desktop sddm konsole dolphin \
  powerdevil kscreen plasma-pa plasma-nm xdg-desktop-portal-kde
sudo systemctl enable sddm
sudo reboot
```

Left out: `bluedevil`, which is optional for Bluetooth, and `breeze-gtk`/`kde-gtk-config` for GTK app theming.

## 10. Final check in a Plasma session

```text
glxinfo -B            → AMD Radeon 780M Graphics (radeonsi, phoenix, ACO, DRM 3.64, 7.2.10-1-cachyos)
prime-run glxinfo -B  → NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2
```

The desktop runs on the AMD iGPU, and `prime-run` switches to the 4060.

## Still open

- **In-game test:** launch a game from Steam with `prime-run gamemoderun mangohud %command%` and check that MangoHud reports the RTX 4060.
- **NVIDIA idle power draw (optional):** set up runtime power management if the 9 W idle draw on battery matters.
