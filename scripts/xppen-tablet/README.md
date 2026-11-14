# XP-Pen tablet driver on `asus-vivobook`

**Status (2026-10-31):** not installed. Kartik removed `xppen-tablet` with `pacman -Rns` at 09:14 on 2026-10-31 (`/var/log/pacman.log`), and `~/build`, including `~/build/xppen-pkg`, no longer exists. The vendor tarball isn't in `~/Downloads` either. To reinstall, recreate `~/build/xppen-pkg` and download the Linux tarball from the link below. If XP-Pen no longer offers 4.0.15 build 260422, follow "Upgrade to a new driver release" to bump `_pkgver`, `_build` and `sha256sums` first. The rest of this file describes the 2026-10-18 setup.

XP-Pen's official Linux driver (PenTablet 4.0.15, build 260422) was installed on `asus-vivobook` (hostname `archlinux`, Arch Linux with CachyOS repos, see `docs/archlinux-pacman-config.md`) as a local pacman package, `xppen-tablet`. The tablet is an XP-Pen Star G640 (USB `28bd:0914`). Set up on 2026-10-18; everything below was verified by running the commands on the laptop that day.

XP-Pen ships the driver as prebuilt binaries with its own copy of Qt 5.6, not source, so nothing is compiled. The PKGBUILD repackages the vendor tarball so pacman tracks every file, instead of running the tarball's `install.sh`, which copies files loose into `/usr` and has to be undone by hand.

## Files here

| File | What it is |
|---|---|
| `PKGBUILD` | Builds `xppen-tablet` from `XPPenLinux<version>-<build>.tar.gz`. |
| `70-xppen-tablet.rules` | udev rule installed to `/usr/lib/udev/rules.d/`, replacing the vendor's `10-xp-pen.rules`. |
| `xppentablet` | `/usr/bin/xppentablet`, a wrapper that runs `/usr/lib/pentablet/PenTablet.sh`. |
| `xppen-tablet.install` | pacman scriptlet that resets the settings folder's group and modes after every install and upgrade. |

The vendor tarball itself isn't committed. Download it from <https://www.xp-pen.com/download> (the `.tar.gz` for Linux).

## Build and install

From the repo root, with the tarball in `~/Downloads`:

```sh
mkdir -p ~/build/xppen-pkg
cp scripts/xppen-tablet/{PKGBUILD,70-xppen-tablet.rules,xppentablet,xppen-tablet.install} ~/build/xppen-pkg/
cp ~/Downloads/XPPenLinux4.0.15-260422.tar.gz ~/build/xppen-pkg/
cd ~/build/xppen-pkg && makepkg -f && pkexec pacman -U "$(makepkg --packagelist)"
```

`makepkg --packagelist` prints an absolute path, which matters here: pkexec doesn't keep the working directory, so a bare filename fails with `could not find or read package`. pacman's own hook reloads the udev rules but doesn't apply them to a tablet that's already plugged in, so either replug it or run:

```sh
pkexec sh -c 'udevadm trigger --action=change --attr-match=idVendor=28bd &&
  udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput &&
  udevadm settle'
```

The driver autostarts at login from `/etc/xdg/autostart/xppentablet.desktop` (minimised to the tray, `/mini`). Start it by hand from the app menu or with `xppentablet`.

### Upgrade to a new driver release

In `PKGBUILD`, set `_pkgver` and `_build` from the new tarball's name (`XPPenLinux<_pkgver>-<_build>.tar.gz`), reset `pkgrel=1`, and replace the first `sha256sums` entry with the output of `sha256sum` on the new tarball. Then build and install as above. Before trusting a new release, check its `install.sh` and `App/lib/udev/rules.d/` for anything new the PKGBUILD doesn't install yet.

### Remove

```sh
pkexec pacman -R xppen-tablet
```

Don't use the vendor's `uninstall.sh`: it deletes files out from under pacman, and its icon path (`pentablet.png`) doesn't match the installed `xppentablet.png` anyway.

## Check it's working

```sh
pacman -Qkk xppen-tablet                 # expect "0 altered files"
getfacl -p /dev/uinput | grep kartik     # expect user:kartik:rw-
lsusb | grep 28bd                        # expect the tablet
```

Started from a terminal, `xppentablet /mini` logs the detected model (`DeviceListLabel: "Star G640"`) and `open uinput ok` / `open uinput absmouse ok`. `open uinput failed` means the ACL on `/dev/uinput` is missing; rerun the `udevadm trigger` commands above. A single `SentCmd(0,1,0) Failed` line also appears on a working setup.

## Differences from the vendor installer

**Seat ACLs instead of world-writable devices.** The vendor rule sets `MODE:="0666"` on `/dev/uinput` and every `28bd` USB device, so any local user or process could inject keyboard and mouse input. `70-xppen-tablet.rules` uses `TAG+="uaccess"` instead, so systemd-logind grants read/write only to the user logged in at the machine. The rule is numbered below `73-seat-late.rules`, where uaccess tags take effect, or the tag would be ignored. The trade-off: the driver only works for that user, not over SSH or from a second login.

**Config writable by `wheel`, not by everyone.** The binary has `/usr/lib/pentablet/conf/xppen/` hardcoded as its settings folder and saves `config.xml` and the `.ini` files there, so the desktop user must be able to write to it. The vendor installer makes the folder `0777` and the files `0666`, so any local user could edit the settings or swap a file for a symlink. Since pkgrel 3 the PKGBUILD hands the folder and those files to group `wheel` instead. The folder is `2775` and the files `0664`, all `root:wheel`. Members of the group can write the files in place, or create a temporary file and rename it over one, which is how Qt's `QSaveFile` and `QSettings` save. The setgid bit keeps those new files in `wheel`. The folder has no sticky bit, because that would block the rename: the files belong to root. Other users can read the settings but can't change, delete or add anything. The files are listed in `backup=()`, so pacman keeps your settings across upgrades and saves a `.pacnew` instead of overwriting them. `Template.xml` keeps the tarball's `root:root` `0644`, as the vendor installer leaves it. Settings are shared by everyone in the group.

What remains: anyone in `wheel` can change the tablet settings, for example remap its buttons to other keystrokes. `wheel` members can already run anything as root through `sudo` or `pkexec`, so this grants them nothing new. Saving still fails when the driver runs without `wheel` in its groups: as another user, or in a session that started before the user joined `wheel`, which needs a fresh login.

**Permissions reapplied on every install and upgrade.** On upgrade, pacman leaves an existing folder's mode and group alone, and keeps an edited backup file as it is. Without help, an upgrade from pkgrel 2 would keep the vendor's `0777` folder and `0666` files. So `xppen-tablet.install` (`post_install` and `post_upgrade`) resets the folder to `2775` and the four files to `0664`, all `root:wheel`, after every install or upgrade, and no fix by hand is needed. It locks the folder first, then skips any of the four that is a symlink or has a second hard link, since another user could have planted one while the folder was world-writable. A skipped file gets an `xppen-tablet: skipped` line, and pacman reports the scriptlet as failed. Replace such a file with a plain one and reinstall. Each run also gives a file the GUI saved back to root; it stays group-writable, so saving keeps working.

The scriptlet can't read the PKGBUILD, because makepkg ships it as-is. To use another group, change `_confgroup` in `PKGBUILD` and `_xppen_confgroup` in `xppen-tablet.install` together; the build stops with an error if they differ. The next install or upgrade then moves the folder and files to the new group.

Saving settings from the GUI is still untested. It was never tried with the vendor's `0777` either. The save sequence itself was checked on 2026-11-14, with the same layout reproduced in a user namespace: create a temporary file, copy the old file's mode, rename it over the root-owned file. It succeeded here, and failed with `Operation not permitted` in a sticky `1777` folder, which is why that alternative was dropped. Retest after the next install:

1. `id -nG` in the session that will run the driver lists `wheel`.
2. `stat -c '%A %U:%G %n' /usr/lib/pentablet/conf/xppen /usr/lib/pentablet/conf/xppen/*` shows `drwxrwsr-x root:wheel` on the folder, `-rw-rw-r-- root:wheel` on `config.xml` and the `.ini` files, and `-rw-r--r-- root:root` on `Template.xml`.
3. Run `xppentablet`, change one pen-button mapping in the settings window and save it. Then quit the driver completely (`pkill -x PenTablet` if it stays in the tray).
4. Run the `stat` command again, adding `%y` to the format. `config.xml` should have a new modification time, with no temporary file left beside it. An owner of `kartik:wheel` means the GUI saved by renaming, and `root:wheel` means it wrote in place. Both are fine, though `pacman -Qkk xppen-tablet` may then report the changed owner.
5. Start `xppentablet` again and check the mapping is still there. If it isn't, run `xppentablet` from a terminal and look for a permission error when saving.

**A wrapper, not a symlink.** `PenTablet.sh` works out which binary to run from its own name and directory. A `/usr/bin/xppentablet` symlink to it made it run `/usr/bin/xppentablet` again, looping until the shell reported `shell level (1000) too high`. The wrapper `exec`s the script by its real path.

**No `/tmp` lockfile.** `install.sh` pre-creates `/tmp/qtsingleapp-Pentab-9c9b-lockfile` as `0666` so several users can share one instance. That file is gone after any reboot (`/tmp` is tmpfs), and a single user doesn't need it, so the package doesn't create it.

**`!strip`.** The bundled Qt libraries and the binary are installed exactly as shipped.

## Runtime notes

The driver is an X11 (`xcb`) Qt app, so under the Plasma Wayland session it runs through XWayland. Its settings window only lists XWayland's view of the screens (a single `Monitor1(0,0,1920,1080)` on 2026-10-18). Pen input goes through uinput virtual devices, so it doesn't depend on X11. Every library the binary and its `libqxcb.so` link against, beyond the bundled Qt and ICU, was already installed; the PKGBUILD lists them in `depends` so a fresh install pulls them in. The build needs `base-devel`.

## State on 2026-10-18

Installed `xppen-tablet 4.0.15.260422-2` (pkgrel 1 had the symlink loop). `pacman -Qkk xppen-tablet` reported 110 files, 0 altered. After the `udevadm trigger`, `kartik` had `rw` ACLs on `/dev/uinput` (built into the CachyOS kernel, not a module), the tablet's `hidraw6`–`8` nodes and `/dev/bus/usb/007/004`. A test launch of `xppentablet /mini` detected the Star G640 and opened uinput. Drawing with the pen and the settings GUI itself haven't been tried yet. `PKGBUILD` and `xppentablet` pass `shellcheck` 0.11.0 and `shfmt` 3.14.1, and the packaging went through a code-review pass with no findings.
