# External monitor flicker — amdgpu/picom diagnosis (asus-vivobook, 2026-08-30)

Kartik reported display flickering, unsure software vs. hardware, and asked for the software side
to be ruled out first via the `linux-sysadmin` skill before he checks hardware himself. Confirmed:
the flickering display is the external monitor (ASUS VG259Q3A, DisplayPort, 1920x1080@180Hz,
primary), not the laptop's built-in eDP panel — that output is connected but currently inactive.

## Setup confirmed sane

`asus-vivobook` is the VFIO passthrough laptop (see `laptop-vfio-passthrough.md`). Verified the
RTX 4060 is still correctly isolated to `vfio-pci` and untouched by any of this — the desktop is
driven entirely by the AMD Radeon 780M iGPU (`amdgpu`, Phoenix, DCN 3.1.4) via the AMDGPU-PRO
userspace stack (Mesa 26.1.3). No leftover `amdgpu-dkms` module, no DRI/driver conflict. This
ruled out a passthrough-related driver clash as the cause.

## Two software issues found and fixed

1. **Weak compositor backend, no vsync.** `picom` was launched via
   `~/.local/share/dwm-titus/scripts/autostart.sh` with `--backend xrender` and no vsync flag
   (picom v13 has vsync off by default unless passed explicitly). Combined with real
   `AMDGPU(0): get vblank counter failed` / `drmmode_do_crtc_dpms cannot get last vblank counter`
   entries in `/var/log/Xorg.0.log`, this is a known tearing/flicker combination.

   Fixed in `autostart.sh` (this is the live deployed dwm-titus config under `~/.local/share`, not
   the read-only `dwm-titus-main/` reference clone — safe to hand-edit per `AGENTS.md`):
   - `PICOM_BACKEND` default changed `xrender` → `glx`.
   - Added a new `PICOM_VSYNC` var (default `1`) that appends `--vsync` to the picom launch line.
   - Both stay overridable via env vars if `glx` misbehaves (`PICOM_VSYNC=0` to revert to old
     behavior).
   - `sh -n` syntax-checked clean after editing.
   - **Not yet live** — takes effect on picom restart (logout/login, or the dwm control-center's
     `restart-picom` action).

2. **`TearFree` left at `auto`.** No override existed in `/etc/X11/xorg.conf.d/` (was empty).
   Added `/etc/X11/xorg.conf.d/20-amdgpu-tearfree.conf`:

   ```text
   Section "Device"
       Identifier "AMDgpu"
       Driver "amdgpu"
       Option "TearFree" "true"
   EndSection
   ```

   Kartik applied this himself via `sudo cp` (2026-08-30). **Also not yet live** — needs a
   logout/reboot to restart X, which Kartik has deliberately deferred so he can verify the fix
   deliberately rather than losing the current session.

## Real root cause found (upstream kernel bug, confirmed via web search)

`sudo journalctl -k -b | grep -iE 'amdgpu|drm|gpu'` surfaced a genuine kernel WARNING at boot
(11:24:04, ~1s after Xorg started probing outputs):

```text
amdgpu 0000:64:00.0: [drm] REG_WAIT timeout 1us * 100 tries - dcn31_program_compbuf_size line:142
WARNING: .../dcn31/dcn31_hubbub.c:151 dcn31_program_compbuf_size+0xd0/0x220 [amdgpu]
```

Backtrace: `drm_atomic_connector_commit_dpms` → `amdgpu_dm_atomic_commit_tail` → `dcn31_program_compbuf_size`.

This is a documented, unresolved upstream amdgpu bug specific to **DCN 3.1 display hardware**
(Radeon 780M/Phoenix is DCN 3.1.4) — reported independently across Gentoo, Arch, CachyOS, and the
freedesktop.org dri-devel/amd-gfx mailing lists, spanning kernel 6.11 through 7.0+, no permanent
fix as of this session. It fires during display atomic commits tied to DPMS (sleep/wake), mode
changes, and — matching this exact setup — switching to or hotplugging an external display.
Severity varies by report: some describe it as log noise only, others tie it to visible flicker or
session instability during monitor/lid events.

Sources:

- <https://github.com/CachyOS/linux-cachyos/issues/810>
- <https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg528230.html>
- <https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg122029.html>
- <https://forums.linuxmint.com/viewtopic.php?t=442975>
- <https://forums.gentoo.org/viewtopic.php?t=1173119>

**Conclusion: this is software, not hardware.** A cable/monitor swap won't fix a kernel driver bug
in DC hubbub's compressed-buffer-size programming. The `TearFree`/picom fixes above address a
separate, real tearing issue found in the same session and are worth keeping regardless, but they
will not resolve this specific WARNING/flicker class. No permanent upstream fix exists yet; the
only practical mitigation is avoiding the triggers (screen sleep/DPMS, monitor hotplug/replug,
mode/refresh-rate switches) until an upstream fix lands. Kartik still needs to confirm whether the
flicker he's seeing actually correlates with those triggers — that would close the loop on this
being the confirmed cause rather than just a plausible one.

## Status / open items

- [x] Kartik logged out to make the `TearFree` + picom `glx`/`vsync` changes live (2026-08-30).
      Flicker gone immediately after — not yet confirmed permanent; Kartik will report back if it
      recurs.
- [ ] Kartik to confirm whether flicker coincides with display sleep/wake, DPMS/screensaver,
      brightness changes, or monitor unplug/replug — would confirm the `dcn31_program_compbuf_size`
      bug as the actual cause.
- [ ] No further action planned on the hardware side unless the above steps fail to reduce/explain
      the flicker.
- [ ] Watch for a kernel update — this is a bleeding-edge kernel (7.1.8, Debian sid/forky), and the
      `dcn31_program_compbuf_size` bug class does get touched occasionally upstream, though none of
      the sources above report a confirmed fix yet.
