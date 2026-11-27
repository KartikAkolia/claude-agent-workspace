# External-only display with hotplug under dwm

`scripts/dwm-external-display/dwm-external-only.sh` makes the external HDMI monitor the only display while it is connected: 1920x1080 at the highest refresh rate it lists for that mode (180 Hz on the current monitor), primary, at `0x0`, with the internal panel off. When the monitor is unplugged it turns the internal panel back on (`--auto`, which picks 1920x1080 at 144 Hz) and the external output off. In `watch` mode it keeps doing this for the whole dwm session, so plugging or unplugging the cable switches displays within about 2–4 seconds. `scripts/dwm-external-display/dwm-external-only.desktop` starts the watcher at dwm login.

Status: installed on `asus-vivobook` (ASUS Vivobook M6500XV, CachyOS, dwm-titus under SDDM) on 2026-11-17. A real unplug and replug were verified that day from the journal: `HDMI-1-0 disconnected, eDP-1 back on` at 18:51:58, then `HDMI-1-0 at 1920x1080 180.00 Hz, eDP-1 off` at 18:52:08. Start at login is configured and the generated unit's condition matches the session, but a fresh login running it has not been watched yet.

## Why it works this way

The external monitor's `HDMI-1-0` output belongs to the NVIDIA GPU (`NVIDIA-G0`), which the session drives as a reverse PRIME output sink of the `modesetting` provider. dwm-titus's own `dwm-display-setup install` writes a persistent Xorg fragment, `/etc/X11/xorg.conf.d/90-dwm-titus-display.conf`. It refuses a layout that disables the internal panel while displays use reverse PRIME, because the SDDM greeter starts from that config and could end up with no display. So this script holds the layout per session instead. The greeter still shows on the internal panel, and the panel turns off once dwm starts. `dwm-reverse-prime`, which `autostart.sh` runs before XDG autostart, binds the NVIDIA sink first, so `HDMI-1-0` exists by the time the watcher starts.

Hotplug is detected by polling, not by udev. A 90-second capture on 2026-11-17 with `udevadm monitor --kernel --udev --property`, taken across a real unplug and replug, recorded no events at all. `/sys/class/drm/card0-HDMI-A-1/status` also stayed `connected` throughout, even though nvidia-drm runs with `modeset=Y`. Only the X server's RandR state changed. So the watcher reads `xrandr --current` every 2 seconds, and `apply` reads it too. That returns the server's cached state without re-probing connectors, so it doesn't flicker the screen. The same capture showed a one-second disconnected/connected flap while the cable was reseated, so a change has to show on two polls in a row before the watcher acts on it.

`apply` succeeds only once the wanted layout is in place. The watcher retries a failed `apply` on every poll, logging only the first failure for each cable state. That covers a monitor that shows as connected before its mode list (EDID) has been read. `apply` does nothing when the layout already matches: either the external primary at `0x0` at its best rate with the internal off, or the internal lit at `0x0` with the external output off. Repeated runs therefore don't touch the screen. It lights the external before turning the internal off, so a rejected mode never leaves both outputs dark. Each poll reads `xrandr --current` once, and the debounce and `apply` both use that read, so they can't disagree. The watcher exits, logging `cannot reach the X server`, after five failed reads in a row (about 10 seconds), which means the X server is gone, so it can't outlive the session even without systemd. Before its first successful read it allows thirty (about a minute), to ride out login. A single failed read during a provider rebind doesn't stop it.

The watcher owns the layout only when the cable state changes. A layout set by hand or through dwm-titus's display settings stays until the next plug or unplug, which replaces it. The flip side is that if suspend, resume or a DPMS cycle changes the layout while the cable stays put, the watcher doesn't correct it. Run `dwm-external-only` once in that case.

## Install

```bash
install -Dm755 scripts/dwm-external-display/dwm-external-only.sh ~/.local/bin/dwm-external-only
mkdir -p ~/.config/autostart
sed "s|/home/kartik|$HOME|" scripts/dwm-external-display/dwm-external-only.desktop >~/.config/autostart/dwm-external-only.desktop
systemctl --user daemon-reload
systemctl --user restart 'app-dwm\x2dexternal\x2donly@autostart.service'
```

The installed copy is not a symlink, so switching branches in this repo can't change the script the running session uses. Rerun the first `install` line and the restart after changing the script.

A desktop entry's `Exec` can't expand `~`, so the tracked entry names `/home/kartik/.local/bin/dwm-external-only watch` and the `sed` line rewrites it to your own `$HOME`. `OnlyShowIn=X-DWM;` matches dwm-titus's `XDG_CURRENT_DESKTOP=X-DWM:dwm`, so a Plasma session doesn't start it. systemd's XDG autostart generator turns the entry into `app-dwm\x2dexternal\x2donly@autostart.service`, `PartOf=graphical-session.target`, which dwm-titus starts after the display environment is exported and stops with the session.

## Usage

```bash
dwm-external-only          # apply once (also the manual fallback, e.g. after resume)
dwm-external-only watch    # what the autostart entry runs
journalctl --user -u 'app-dwm\x2dexternal\x2donly@autostart.service' -f
```

`DWM_EXTERNAL_OUTPUT` (default `HDMI-1-0`) and `DWM_INTERNAL_OUTPUT` (default `eDP-1`) override the output names. Pointing `DWM_EXTERNAL_OUTPUT` at a disconnected output, such as `DP-1`, exercises the unplug branch without touching the cable. An internal output name that doesn't exist is refused with `no output named ...`, because xrandr itself only warns and exits 0 for one. The mode is fixed at `1920x1080` in the script. If a connected external output doesn't list that mode, `apply` leaves the layout as it is and the watcher keeps retrying, since an unread EDID looks the same. A monitor without 1080p therefore never gets the external-only layout. Edit `mode` for one.

## Undo and recovery

To get the internal panel back right away, run `xrandr --output eDP-1 --auto`, or unplug the monitor and let the watcher do it. To remove the setup:

```bash
systemctl --user stop 'app-dwm\x2dexternal\x2donly@autostart.service'
rm ~/.config/autostart/dwm-external-only.desktop ~/.local/bin/dwm-external-only
systemctl --user daemon-reload
```
