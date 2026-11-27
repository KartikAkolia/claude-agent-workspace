# Device power saving on asus-vivobook

`scripts/device-power-saving/disable-device-power-saving.sh` turns off device-level power saving on `asus-vivobook`: USB and PCI runtime power management, PCIe ASPM, NVMe autonomous power-state transitions, HDA audio power saving, the NVIDIA dGPU's dynamic power management and Wi-Fi power saving. System suspend, hibernate and lid handling are untouched. It targets that laptop's CachyOS install (Arch, GRUB, mkinitcpio, NetworkManager) and runs as root, re-running itself under `sudo` when started as an ordinary user. Every install and every undo is a recorded run with a private, recoverable backup, and both need a reboot to take full effect. Its helper `scripts/device-power-saving/device-power-saving-config.py` does the GRUB editing and the effective-config checks, and `scripts/device-power-saving/test_device_power_saving.py` tests both against a fake root. Status: installed on `asus-vivobook` as three stacked runs and reboot-verified on 2026-11-12 per [handoff.md](handoff.md) (open item 53). The late pass's after-resume run had not been verified by then (item 51). The dated session entries in handoff.md (2026-10-24, 2026-11-10 and 2026-11-12) hold the history.

## Usage

```bash
python3 -m unittest discover -s scripts/device-power-saving -p test_device_power_saving.py -v   # first; fake root, no privileges
pkexec "$PWD/scripts/device-power-saving/disable-device-power-saving.sh"                        # install
pkexec "$PWD/scripts/device-power-saving/disable-device-power-saving.sh" --undo BACKUP_DIRECTORY
pkexec "$PWD/scripts/device-power-saving/disable-device-power-saving.sh" --recover BACKUP_DIRECTORY
```

Run these from the repository root. The 2026-11-10 and 2026-11-12 runs recorded in handoff.md used `pkexec`. A successful install ends by printing its exact undo command. The script resolves the path it's given, so `--undo /var/lib/device-power-saving/current` also names the most recent run, the only one undo accepts. Running the install again, for example after changing the script, stacks a new run on top of the last one. Reboot after an install, an undo or a recovery.

Before it touches anything it needs `device-power-saving-config.py` in the same directory as the script's resolved path, and `python3`, `grub-mkconfig`, `mkinitcpio`, `modprobe`, `nmcli`, `iw`, `udevadm`, `flock`, `setpci` and `systemctl` on `PATH`. `/etc/default/grub` must hold exactly one `GRUB_CMDLINE_LINUX_DEFAULT` assignment as a single quoted literal line, and `/boot/grub/grub.cfg` must already exist. `/var/lib` needs room for a full copy of `/boot` during every run. Two things the script can't check for itself also matter. The `modconf` hook must be in mkinitcpio's `HOOKS`, or the new `modprobe.d` options won't reach the initramfs for modules loaded from it. And every mkinitcpio preset must write only under `/boot`, because nothing outside `/boot` is backed up. Both held on 2026-11-15: `HOOKS` includes `modconf`, and the `linux-cachyos` and `linux-lts` presets write `/boot/initramfs-*.img`. Only one operation runs at a time. A second fails its `flock` with "another power-policy operation is running".

## What it changes

The script manages eight files. Each one's index is its name inside a backup (`before/<i>`, `after/<i>`).

| Index | File | Content |
| --- | --- | --- |
| 0 | `/etc/udev/rules.d/99-no-runtime-pm.rules` | Sets `power/control` to `on` for every USB and PCI device on `add` and `bind` |
| 1 | `/etc/modprobe.d/no-power-saving.conf` | `snd_hda_intel power_save=0 power_save_controller=N`, `nvidia NVreg_DynamicPowerManagement=0x00`, `mt7921e disable_aspm=Y` |
| 2 | `/etc/NetworkManager/conf.d/wifi-powersave-off.conf` | `[connection]` `wifi.powersave=2`, the global value for Wi-Fi profiles left at `default` |
| 3 | `/etc/default/grub` | Sets `usbcore.autosuspend=-1 pcie_aspm.policy=performance nvme_core.default_ps_max_latency_us=0` in `GRUB_CMDLINE_LINUX_DEFAULT` |
| 4 | `/etc/systemd/system/device-power-late.service` | Oneshot unit for the late pass, ordered after `systemd-udev-trigger.service`, `sound.target` and `suspend.target` |
| 5 | `/etc/systemd/system/multi-user.target.d/device-power-late.conf` | `Wants=device-power-late.service`, so the late pass runs at boot |
| 6 | `/usr/local/sbin/device-power-late` | The late pass itself, always mode 0755 |
| 7 | `/etc/systemd/system/suspend.target.d/device-power-late.conf` | The same `Wants=`, so the late pass runs again after resume |

Indices 0–2 and 4–7 are whole files. When one of them replaces an existing file, it keeps that file's mode, owner, ACLs, xattrs and SELinux label. New files get 0644. If the parent directories for indices 4–7 are missing, the script creates them world-readable. Everything else it creates is private (umask 077). The GRUB file is rewritten the same way, keeping its attributes, and only its command line changes. The edit drops every token whose key is one of the three managed parameters, wherever it sits on the line, and appends the managed values. Every other token and line stays as it was.

Every NetworkManager Wi-Fi profile that exists at install time is set to `802-11-wireless.powersave 2` (`disable`), and each one is read back to confirm. Profiles created later stay at `default`, which `nm-settings-nmcli(5)` defines as "use the globally configured value", so the drop-in at index 2 covers them. That's how the policy still held for two newer profiles on 2026-10-31, per handoff.md item 37. The script then runs `mkinitcpio -P` and `grub-mkconfig -o /boot/grub/grub.cfg`, and reloads the udev rules, the systemd units and the NetworkManager config.

Last, it applies what it can to the running system. This step runs only after the run is recorded as complete, and it's best effort, so none of it can fail the install. It sets `usbcore` autosuspend to `-1`, the ASPM policy to `performance` and both `snd_hda_intel` parameters, runs `iw dev <iface> set power_save off` on each wireless interface, and starts `device-power-late.service` once. The kernel command line, the NVMe latency and NVIDIA's `DynamicPowerManagement` wait for a reboot (still pending after the 2026-11-10 install, per handoff.md). So does `mt7921e disable_aspm`, because the driver reads it only at probe.

### The late pass

The late pass covers two things no boot-time setting can. First, some drivers, `snd_hda_intel` among them, set `power/control` back to `auto` after the udev rule has run. On 2026-10-24 that was the three HDA controllers and the webcam. Second, firmware that owns ASPM keeps L0s/L1 on whatever `pcie_aspm.policy` says. On `asus-vivobook` the kernel logs `ACPI FADT declares the system doesn't support PCIe ASPM`, and the BIOS kept L1 on the Wi-Fi link (`02:00.0` and root port `00:02.2`) and the NVMe link (`03:00.0` and root port `00:02.4`) when read as root on 2026-10-24 and again on 2026-11-12, per handoff.md.

The pass first waits for `udevadm settle`, giving up after 30 s and carrying on. Then it sets every USB and PCI `power/control` that isn't `on` to `on`, logging each device. It repeats that 3 s later, because drivers that finish probing asynchronously can turn runtime PM back on after the first pass. Those devices are logged with a `recheck:` prefix. Last, it clears the ASPM bits (bits 0–1 of the PCIe Link Control register, `CAP_EXP+10.w`) with `setpci` wherever they're set. It goes deepest devices first, so each endpoint is disabled before its upstream bridge. Devices with no PCIe capability are skipped, and so is any that reads `ffff`. That value means the device isn't answering, and a masked write would then set Link Disable. A failed ASPM write fails the unit, while a failed `power/control` write only warns.

## Backups, undo and recovery

State lives in `/var/lib/device-power-saving/`, which is root-only (0700). It holds `lock`, a `current` symlink to the most recent completed install that hasn't been undone, and one `run.XXXXXX` directory for each install or undo that gets past its first checks, whether or not it then succeeds. A run directory holds:

- `parent`: the run that `current` pointed at when this one started, empty if none. This is how runs stack.
- `before/<i>`: a copy of each managed file as it was. It's absent if the file didn't exist.
- `after/<i>`: what an install wrote. `after/3` is the GRUB file after the install.
- `profiles`: one `<uuid> <value>` line per Wi-Fi profile at the start, where `0`–`3` mean `default`, `ignore`, `disable` and `enable`. `profile-list` is the raw `nmcli` listing.
- `boot/`: a full copy of `/boot`. It's deleted once the run succeeds or aborts early. A run that fails after making changes keeps it.
- `new-grub`, `effective-modules`, `undo-grub` and `undo-source`: working files. An undo writes `undo-grub` into the run it is undoing, and records that run's path in its own `undo-source`.
- Markers. `pending` means managed writes are in progress, or a rollback didn't finish. `complete` means the install finished. `undone` means the install has since been undone. `aborted` means the run failed before changing anything.

`--undo` accepts only a completed, not-yet-undone run that `current` points at, so stacked runs come off newest first. After each undo, `current` moves to that run's `parent`. As of 2026-11-12, per handoff.md, the stack on `asus-vivobook` was `run.LMQ3Rv`, then `run.QoPcmy`, then `run.ePjdhx`. To remove the policy completely, undo them in reverse order, then reboot once.

Undo refuses, changing nothing, in four cases:

- Any file the run installed now differs from what it installed.
- A file the run didn't install now exists. A run from before the late pass has no `after/4`–`after/7`, so those files have to be gone first, which undoing the newer runs does.
- Any backed-up Wi-Fi profile no longer reads `disable`.
- The managed GRUB tokens aren't exactly what the install set. The helper then says to undo by hand.

Otherwise undo restores the backed-up files, deleting any that didn't exist before, and restores each profile's earlier value. It swaps the managed GRUB tokens back to whatever the pre-run file had, so unrelated later GRUB edits survive. If the file already had `usbcore.autosuspend=-1` before the run, undo keeps it. Then come the same rebuilds and reloads and a `systemctl reset-failed device-power-late.service`. Undo doesn't touch live sysfs or Wi-Fi state, so reboot afterwards. An undo is itself a run with its own snapshot. If one fails, it rolls back to the installed policy and leaves the source backup intact for a retry.

A run moves through three phases. Until it creates its `pending` marker, it only reads and snapshots. A failure there leaves the system untouched, deletes the run's `/boot` copy and marks the run `aborted` ("Nothing was changed; partial run kept for diagnosis"). That doesn't block later runs. Once `pending` exists, any failure rolls back automatically, including an `INT`, `TERM` or `HUP` signal:

- Every managed file comes back from `before/`, and the Wi-Fi profiles are restored.
- The `/boot` copy is copied back over `/boot`. That restores initramfs images a failed `mkinitcpio` half-wrote, so the old `grub.cfg` matches its images again. It doesn't delete files the failed run added to `/boot`.
- The bookkeeping (`current`, `complete`, `undone`) is put back.
- udev, systemd and NetworkManager are reloaded.

The run then exits 1 with "Previous config, profiles and boot files restored". If any rollback step fails, it prints `RECOVERY INCOMPLETE: do not reboot; retry: … --recover <run>` and leaves `pending` in place. Every later install or undo then refuses with "unfinished recovery" until `--recover` succeeds.

`--recover` accepts only a `run.*` that still has `pending`, has no `complete`, and still has its `before/3`, `boot/`, `profiles` and `parent`. It overwrites every managed file, the Wi-Fi profiles and `/boot` from that snapshot without checking for later edits. So run it straight after the failure, before changing anything else, and reboot afterwards.

Don't delete a run directory whose install hasn't been undone, and never one that still has `pending`. One with an `aborted` marker, or an empty one, failed before changing anything and can go. Runs from before the SYS-7 fix still hold a full `/boot` copy. On 2026-11-14 that was about 1.1 GB in total, per the [script audit](script-audit-2026-11-14.md). Their `boot/` can be removed from runs marked `complete` or `undone`, never from one with `pending`.

## Safety and invariants

Most refusals happen before the first managed write. That covers the tool and helper checks, undo's conflict checks, the refusal of symlinked or non-regular managed paths, and reading every Wi-Fi profile. It also covers the GRUB edit, which is computed and `bash -n`-checked on a copy. Three checks can only run later, and a failure in any of them rolls back. The effective-modules check runs after the files are placed but before `mkinitcpio`. Each Wi-Fi profile is read back after it's set. The check of the generated `grub.cfg` runs after `grub-mkconfig`.

Every write to a managed file, restores included, goes through `place()`. It copies into a sibling `.device-power.XXXXXX` file in the destination directory, then renames that over the target with `mv -fT`. A failed copy never truncates a live file, and an abandoned staging file is removed on exit.

SYS-6: `place()` and the attribute copies use `cp --preserve=all --no-preserve=timestamps`. That keeps mode, owner, ACLs, xattrs and SELinux labels but gives the file a fresh mtime, so a rewritten `/etc` file reads as changed now rather than carrying the old file's date. `all` is deliberate. GNU `cp` treats a failure to keep an SELinux context or xattrs as non-fatal under `all`, while an explicit `context` fails on a system without SELinux.

SYS-7: a run's `/boot` copy is deleted only after its `pending` marker is gone. An interrupted delete therefore can't leave a half-deleted copy for `--recover` to restore. Nothing reads a finished run's copy: `--recover` takes only runs still marked `pending`, and an undo takes a fresh `/boot` snapshot. A run that fails after making changes keeps its copy, whether its rollback finished or it's still waiting for `--recover`. The `pending` marker itself is created while the run is still in its snapshot phase. If creating it fails, or the run dies before entering the pending phase, the tidy step removes the marker along with the `/boot` copy.

Backups store files by index, so the file list is append-only and `/etc/default/grub` stays at index 3. Backups from before the late pass lack indices 4–7, and undo handles that as described above.

`profile_value`, and `require_disabled`, which calls it, must only be called as a plain assignment or a plain command. Never call them under `if`, `||`, `&&` or `[[ ]]`, where errexit is suspended and the `die` inside the command substitution would be masked. When a profile can't be read, `require_disabled` dies with a distinct "cannot read Wi-Fi policy" message, so a parse failure is never reported as a policy change. `nmcli -g` prints the enum name, such as `disable`, on nmcli 1.58. A leading number, as in `2 (disable)`, is accepted too.

The rollback runs from the `EXIT` trap, so none of this is power-loss atomic. A power cut or `SIGKILL` during the pending phase skips the rollback. The `pending` marker survives, though, so the next run demands `--recover`.

## The config helper

`scripts/device-power-saving/device-power-saving-config.py` reads its input and prints to stdout. It never writes files. On any refusal it exits non-zero with `error: …`.

| Operation | Input | Does |
| --- | --- | --- |
| `grub FILE` | GRUB defaults | Prints the file with the managed parameters set |
| `undo-grub CURRENT BEFORE` | Current defaults and the run's `before/3` | Prints `CURRENT` with the managed tokens swapped back to `BEFORE`'s |
| `modules` | `modprobe --showconfig` on stdin | Checks the effective module options |
| `boot` | Generated `grub.cfg` on stdin | Checks every normal kernel entry |

It edits only a literal. It needs exactly one `GRUB_CMDLINE_LINUX_DEFAULT` assignment, optionally `export`ed, on one line and in single or double quotes, with an optional trailing comment. It refuses a value containing a backslash, `$`, a backtick or a quote (expansions, escapes or embedded quotes). It also refuses a line continuation, and a `--` token, which separates kernel arguments from init arguments. The refusals for those characters and for `--` say to edit the line by hand. Tokens are matched by exact key. So `x.usbcore.autosuspend=7` is left alone, while every duplicate `usbcore.autosuspend=` is replaced by one managed value. Text in the trailing comment never counts, and running it on its own output changes nothing.

`modules` takes the last `options` value for each module parameter as the effective one, treating `-` and `_` in module names alike. It requires these values:

- `snd_hda_intel power_save` is 0.
- `power_save_controller` is false: `n`, `no`, `0` or `false`, in any case.
- `nvidia NVreg_DynamicPowerManagement` is 0, in decimal or `0x` hex.
- `mt7921e disable_aspm` is true: `y`, `yes`, `1` or `true`.

A conflict elsewhere fails the install with "resolve modprobe.d or kernel-command-line conflicts and rerun", before any boot file is built. The check covers configuration only. `modprobe --showconfig` lists options whether or not the module is in use. That's how a dead Intel `iwlmvm` line kept passing after the Wi-Fi card was swapped for a MediaTek MT7902, until it was replaced with the `mt7921e` line on 2026-11-12 (handoff.md).

`boot` reads every `linux`, `linuxefi` and `linux16` line and skips rescue entries (`single`, `recovery`, `systemd.unit=rescue.target`, `systemd.unit=emergency.target`). On every other entry, the last value of each managed parameter must be the requested one. Otherwise it fails with "check GRUB overrides". It also needs at least one normal entry to check. Only installs run this check.

## After a reboot

These come from the handoff.md verification steps and use `asus-vivobook`'s interface and PCI names:

```bash
cat /proc/cmdline                                               # has all three parameters
cat /sys/module/usbcore/parameters/autosuspend                  # -1
cat /sys/module/nvme_core/parameters/default_ps_max_latency_us  # 0
grep Dynamic /proc/driver/nvidia/params                         # DynamicPowerManagement: 0
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status      # active (the dGPU)
cat /sys/module/snd_hda_intel/parameters/power_save             # 0
cat /sys/module/mt7921e/parameters/disable_aspm                 # Y
iw dev wlp2s0 get power_save                                    # Power save: off
grep -l '^auto$' /sys/bus/{usb,pci}/devices/*/power/control     # prints nothing
journalctl -u device-power-late -b -o cat                       # ends with "Deactivated successfully"
pkexec lspci -vv | grep -c 'ASPM L[01s ]*Enabled'               # 0
```

`cat /sys/module/pcie_aspm/parameters/policy` stays at `[default]` on this firmware, not `[performance]`. The late pass and `mt7921e disable_aspm` do that job instead. At boot, the `ASPM disabled on` lines should name only NVMe `03:00.0` and its root port `00:02.4`, because the driver already clears the Wi-Fi pair at probe. The kernel line `mt7921e 0000:02:00.0: can't disable ASPM; OS doesn't have ASPM control` is expected. That was the 2026-11-12 result. A `recheck:` line names a driver that lost the race. After one `systemctl suspend` and wake, `journalctl -u device-power-late -b` should show a second run, and the checks above should still hold. That after-resume run hadn't been verified as of handoff.md item 51. With the dGPU bound to `vfio-pci` instead, the `nvidia` option is inert ([laptop-vfio-passthrough.md](laptop-vfio-passthrough.md)).

## Testing

```bash
python3 -m unittest discover -s scripts/device-power-saving -p test_device_power_saving.py -v
```

Run it from the repository root. It needs no privileges, and on 2026-11-15 all 33 tests passed in about 17 s. CI runs the same suite (`cd scripts/device-power-saving && python3 -m unittest test_device_power_saving -v`) in `.github/workflows/lint-bash.yml` on any push or pull request that touches a shell script, the suite or the helper.

`GrubTests` call the helper directly. Each `InstallTests` case builds a throwaway root in a temp directory and runs a rewritten copy of the script against it. The root check `((EUID == 0)) ||` becomes `true ||`. Every `/etc/`, `/sys/`, `/var/lib/` and `/usr/local/` prefix points into the temp root, and so does `BOOT_DIR=/boot`. A Python stub stands in for `nmcli`, `modprobe`, `mkinitcpio`, `grub-mkconfig`, `udevadm`, `iw`, `setpci` and `systemctl`, and `sleep` is a no-op. The stub logs every call to `calls` and keeps its state in the fake root. Wi-Fi profiles live in `wifi.json` and PCI Link Control values in `lnkctl.json`. Its `grub.cfg` is built by sourcing the fake GRUB defaults. Marker files inject failures:

- `fail` names a command to fail once. `mkinitcpio` and `grub-mkconfig` leave partial output first.
- `fail-profile` and `fail-setpci` make a profile change or an ASPM write fail.
- `blank-powersave`, `blank-after-modify` and `numeric-powersave` change what `nmcli -g` prints.

Some tests also wrap the real `cp` or `mv`, to fail mid-copy or to send the script a signal. After every run, the suite checks that no `.device-power.*` staging file is left. The script runs under `env --default-signal=HUP,INT,TERM`, because bash can't trap a signal that was ignored on entry, as under `nohup` or a background runner. `POLICY_PID` is exported so that the signal test hits the main script, not a `place()` subshell (SYS-8).

The rewrite is a literal text replacement. The root check must therefore stay spelled `((EUID == 0)) ||`, and every host path must start with one of those four prefixes or go through `BOOT_DIR`. Otherwise the test copy would re-run itself under `sudo` or touch the real host.

What the suite covers:

- GRUB editing and the checks: comments don't satisfy the policy, editing is idempotent and duplicates are replaced exactly, ambiguous or dynamic assignments are rejected, and undo keeps quoting, comments and unrelated edits but refuses changed managed tokens. Rescue entries are skipped in `grub.cfg`, and a later override fails the check. Conflicting module options fail, while overridden earlier ones pass.
- Install and undo: undo restores the content and modes of `/etc` and `/usr` and the Wi-Fi profiles. Stacked runs undo newest first. An unrelated GRUB edit survives undo. Undo handles a backup from before the late pass, and a changed drop-in or profile blocks it.
- Failures: a failure of `mkinitcpio`, `grub-mkconfig`, `udevadm` or `systemctl`, of a profile write, or of the generated-`grub.cfg` or effective-modules check rolls everything back, `/boot` included. A GRUB rejection comes before any write, and a partial copy never truncates a live file. `INT`, `TERM` and `HUP` during a write roll back with exit 1. Unreadable profiles are reported on install and on undo. An early failure leaves an `aborted` run without `/boot`, and a failed undo keeps its source and can be retried. An incomplete rollback blocks later runs until `--recover` restores the originals.
- The SYS-6 and SYS-7 fixes: rewritten files get a fresh mtime and keep their modes, and only runs that fail after making changes keep a `/boot` copy.
- The late pass: it clears ASPM downstream first, skips `ffff`, only warns on an unwritable control and fails on an ASPM write error. A failed first start leaves the install complete, and the helper is made executable even when an old copy wasn't.

Real hardware, real tool output beyond the formats the stubs print, root ownership, SELinux labels and power loss aren't covered.

## Known gaps

The late pass doesn't re-run after hibernate or after a VFIO driver rebind. The hibernate targets were masked on `asus-vivobook` as of the 2026-11-11 handoff entry. Undo leaves the late pass's empty drop-in directories behind. `pcie_aspm.policy=performance` does nothing on this firmware but is harmless.

Three follow-ups from the 2026-10-31 review (handoff.md item 43) are still open in the current code:

1. Undo can't skip a backed-up Wi-Fi profile that has since been deleted: it dies with "cannot read Wi-Fi policy". The only way past it is to delete that profile's line from the run's `profiles` file, as root, before undoing (item 37). A profile that has merely changed refuses with "changed; reconcile it before undo" until it's set back to `disable`.
2. An install that fails but rolls back cleanly keeps its full `/boot` copy. Nothing reads that run again, but nothing marks it safe to delete either.
3. If the early-failure tidy itself fails ("could not tidy partial run"), the directory keeps `/boot` and gets no `aborted` marker.
