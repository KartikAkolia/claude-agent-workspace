# Logitech C920 webcam settings on plug-in

`scripts/c920-webcam/install-c920-udev-rule.sh` makes a Logitech C920 (USB `046d:08e5`) come up with the "stable" settings, manual exposure and autofocus off, every time it appears, not just until the next replug or reboot. It installs `scripts/c920-webcam/c920-apply-settings.sh` as a helper, a templated systemd service that runs the helper, and a udev rule that starts the service, then applies the settings to any C920 already plugged in. Run the installer as yourself in a real terminal: every install step goes through `sudo`, and the service runs the helper as root. Status: not installed on the current `asus-vivobook` install. As checked on 2026-11-15, none of the three installed files exists and no C920 is attached (`video0` and `video1` are the laptop's built-in camera). The 2026-11-14 audit lists the C920 udev helper among the things verified only with stubs, not on a real camera ([script-audit-2026-11-14.md](script-audit-2026-11-14.md), SYS-5 and "Still needs Kartik" item 4).

## Why

The settings are the fix from [Chris Titus's article on C920 lag under Linux](https://christitus.com/logitech-c920-linux-driver/). `scripts/desktop-tuis/webcam-tui.sh`'s "stable" preset applies the same fix ([desktop-tuis.md](desktop-tuis.md)), but only for the session: v4l2 controls reset when the camera is replugged or the machine reboots, and that is the gap the rule covers.

The article's control names, `exposure_auto` and `focus_auto`, don't work here: `v4l2-ctl` rejected them as "unknown control" (checked 2026-10-18 on `/dev/video2`). Both scripts use the names the kernel reports, `auto_exposure`, `exposure_time_absolute`, `focus_automatic_continuous` and `focus_absolute`.

## Usage

```bash
scripts/c920-webcam/install-c920-udev-rule.sh            # exposure 250, focus 0
scripts/c920-webcam/install-c920-udev-rule.sh 300 40     # EXPOSURE FOCUS
journalctl -u 'c920-settings@*' -n 20
```

| Argument | Control | Range | Default |
| --- | --- | --- | --- |
| `EXPOSURE` | `exposure_time_absolute` | 3-2047 | 250, the C920's own default |
| `FOCUS` | `focus_absolute` | 0-250 in steps of 5 | 0, infinity |

The installer refuses values outside those ranges (the C920's `focus_absolute` only takes multiples of 5). It checks the digit count before the numeric test, so a value too large for bash's arithmetic is refused rather than slipping past the range check. It needs `v4l2-ctl` from `v4l-utils` and `c920-apply-settings.sh` in the same directory as itself, and it prints the unit and rule before installing them. The values are written into the unit's `ExecStart`, so to change them, rerun the installer with new ones; it replaces all three files.

| Installed path | Contents |
| --- | --- |
| `/usr/local/bin/c920-apply-settings` | a copy of `scripts/c920-webcam/c920-apply-settings.sh`, mode 755 |
| `/etc/systemd/system/c920-settings@.service` | a `Type=oneshot` template whose `ExecStart` runs the helper on `/dev/%I` with the chosen values |
| `/etc/udev/rules.d/99-logitech-c920.rules` | on `add`, pulls in `c920-settings@<videoN>.service` |

To remove it, delete the three files and reload both managers. A camera that is plugged in keeps its current settings until it is replugged.

```bash
sudo rm /usr/local/bin/c920-apply-settings /etc/systemd/system/c920-settings@.service /etc/udev/rules.d/99-logitech-c920.rules
sudo systemctl daemon-reload
sudo udevadm control --reload
```

## How it works

The rule matches `ACTION=="add"` on `SUBSYSTEM=="video4linux"` by USB vendor and product ID (`ATTRS{idVendor}=="046d"`, `ATTRS{idProduct}=="08e5"`) rather than by `/dev/videoN`, because the node number depends on probe order. It also requires `ATTR{index}=="0"`, so only the capture node gets the settings, not the C920's UVC metadata node. `TAG+="systemd"` exposes the device as a systemd unit, without which systemd ignores the device's `SYSTEMD_WANTS`. `ENV{SYSTEMD_WANTS}+="c920-settings@%k.service"` then starts one instance per capture node, named after its kernel name (`%k`, for example `video2`).

The rule doesn't set the controls itself. The installer's first version did, and it only worked some of the time, because of how the C920 behaves just after plug-in (see the helper below). A retry loop can't live in the rule either: udev(7) allows `RUN+=` only for very short-running foreground tasks and kills long-running ones once event handling finishes, and recommends a service pulled in through `SYSTEMD_WANTS` instead.

systemd acts on `SYSTEMD_WANTS` only when a device first becomes active (systemd.device(5)), so re-triggering an `add` event wouldn't reach a camera that is already plugged in. The installer therefore finds each C920 capture node itself (sysfs `index` 0, udev `ID_VENDOR_ID=046d` and `ID_MODEL_ID=08e5`) and starts its unit directly. `systemctl start` waits for a oneshot service to finish, and each helper try settles for 2 seconds, so this can take up to about 20 seconds per camera. If the helper fails on any camera, the installer says so and exits 1, leaving the files installed.

### The helper

`c920-apply-settings DEVICE EXPOSURE FOCUS` writes four controls in this order: `auto_exposure=1` (Manual Mode), `exposure_time_absolute=EXPOSURE`, `focus_automatic_continuous=0`, `focus_absolute=FOCUS`. Each auto-mode switch comes before its value because the C920 refuses `focus_absolute` with "Permission denied" while autofocus is still on. The helper then waits 2 seconds and reads every control back with `v4l2-ctl -C`. It exits once all four hold; otherwise it logs which ones didn't and tries again, up to 10 times. Write errors are ignored, since the read-back is the check.

It loops because, straight after plug-in, the C920 accepts every write but sometimes drops some of them. On 2026-10-21 one replug kept exposure but not focus, a boot kept focus but not exposure, and the next replug kept all four. It can also drift off a manual exposure for a second or two after the mode switch while its auto exposure settles (the same day, 250 drifted to 156), which an immediate read-back would miss.

The helper's exit status is `0` when the settings held, `1` when the device disappeared or the settings still hadn't held after 10 tries, and `2` for a wrong number of arguments. The service runs it; it isn't normally run by hand.

## Verification

`journalctl -u 'c920-settings@*' -n 20` shows a line per failed try and ends with `settings held on try N`, `gave up after 10 tries` or `went away, giving up`. The unit has no `RemainAfterExit`, so after a successful run it shows as inactive rather than active; check the journal, not `systemctl is-active`. To read the live values:

```bash
v4l2-ctl -d /dev/videoN -C auto_exposure,exposure_time_absolute,focus_automatic_continuous,focus_absolute
```

## Known gaps

Only product ID `08e5` is matched, so a C920 that reports another product ID gets nothing.
