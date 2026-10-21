# XP-Pen tablet driver on `asus-vivobook`

XP-Pen's official Linux driver (PenTablet 4.0.15, build 260422) is installed on `asus-vivobook` (hostname `archlinux`, Arch Linux with CachyOS repos, see `docs/archlinux-pacman-config.md`) as a local pacman package, `xppen-tablet`. The tablet is an XP-Pen Star G640 (USB `28bd:0914`). Set up on 2026-10-18; everything below was verified by running the commands on the laptop that day.

XP-Pen ships the driver as prebuilt binaries with its own copy of Qt 5.6, not source, so nothing is compiled. The PKGBUILD repackages the vendor tarball so pacman tracks every file, instead of running the tarball's `install.sh`, which copies files loose into `/usr` and has to be undone by hand.

## Files here

| File | What it is |
|---|---|
| `PKGBUILD` | Builds `xppen-tablet` from `XPPenLinux<version>-<build>.tar.gz`. |
| `70-xppen-tablet.rules` | udev rule installed to `/usr/lib/udev/rules.d/`, replacing the vendor's `10-xp-pen.rules`. |
| `xppentablet` | `/usr/bin/xppentablet`, a wrapper that runs `/usr/lib/pentablet/PenTablet.sh`. |

The vendor tarball itself isn't committed. Download it from <https://www.xp-pen.com/download> (the `.tar.gz` for Linux).

## Build and install

From the repo root, with the tarball in `~/Downloads`:

```sh
mkdir -p ~/build/xppen-pkg
cp scripts/xppen-tablet/{PKGBUILD,70-xppen-tablet.rules,xppentablet} ~/build/xppen-pkg/
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

**Config stays world-writable.** The binary has `/usr/lib/pentablet/conf/xppen/` hardcoded as its settings folder and writes `config.xml` there, so the PKGBUILD keeps the vendor's `0777` on the folder and `0666` on `config.xml` and the `.ini` files. These are listed in `backup=()`, so pacman keeps your settings across upgrades and saves a `.pacnew` instead of overwriting them. `Template.xml` keeps the tarball's `0644`, as the vendor installer leaves it. Settings are shared by every user on the machine.

**A wrapper, not a symlink.** `PenTablet.sh` works out which binary to run from its own name and directory. A `/usr/bin/xppentablet` symlink to it made it run `/usr/bin/xppentablet` again, looping until the shell reported `shell level (1000) too high`. The wrapper `exec`s the script by its real path.

**No `/tmp` lockfile.** `install.sh` pre-creates `/tmp/qtsingleapp-Pentab-9c9b-lockfile` as `0666` so several users can share one instance. That file is gone after any reboot (`/tmp` is tmpfs), and a single user doesn't need it, so the package doesn't create it.

**`!strip`.** The bundled Qt libraries and the binary are installed exactly as shipped.

## Runtime notes

The driver is an X11 (`xcb`) Qt app, so under the Plasma Wayland session it runs through XWayland. Its settings window only lists XWayland's view of the screens (a single `Monitor1(0,0,1920,1080)` on 2026-10-18). Pen input goes through uinput virtual devices, so it doesn't depend on X11. Every library the binary and its `libqxcb.so` link against, beyond the bundled Qt and ICU, was already installed; the PKGBUILD lists them in `depends` so a fresh install pulls them in. The build needs `base-devel`.

## State on 2026-10-18

Installed `xppen-tablet 4.0.15.260422-2` (pkgrel 1 had the symlink loop). `pacman -Qkk xppen-tablet` reported 110 files, 0 altered. After the `udevadm trigger`, `kartik` had `rw` ACLs on `/dev/uinput` (built into the CachyOS kernel, not a module), the tablet's `hidraw6`–`8` nodes and `/dev/bus/usb/007/004`. A test launch of `xppentablet /mini` detected the Star G640 and opened uinput. Drawing with the pen and the settings GUI itself haven't been tried yet. `PKGBUILD` and `xppentablet` pass `shellcheck` 0.11.0 and `shfmt` 3.14.1, and the packaging went through a code-review pass with no findings.
