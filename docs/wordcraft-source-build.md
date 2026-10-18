# WordCraft — source build and auto-update on `asus-vivobook`

[WordCraft](https://github.com/storytold/wordcraft) (a Rust word processor that reads and writes `.docx`) is built from source on `asus-vivobook` (Arch Linux with CachyOS repos, see `docs/archlinux-pacman-config.md`) and installed as a local pacman package, so `pacman -R wordcraft` removes it cleanly. A root systemd timer pulls upstream on odd days of the month and rebuilds and reinstalls only when a new commit has landed. Set up on 2026-10-18; everything below was verified by running the commands on the laptop that day, not from pasted output.

## Where things live

| Path | What it is |
|---|---|
| `~/build/wordcraft/` | Shallow clone of `storytold/wordcraft` (`main`). Cargo's `target/` stays here so rebuilds are incremental. |
| `scripts/wordcraft/` (this repo) | The versioned originals: `PKGBUILD`, `wordcraft-update`, `wordcraft-update.service`, `wordcraft-update.timer`. |
| `~/build/wordcraft-pkg/` | makepkg's working directory: a deployed copy of the `PKGBUILD`, plus the built packages, `src/`, `pkg/` and an optional `HOLD` file. |
| `/usr/local/bin/wordcraft-update` | Deployed updater, `root:root 0755`. |
| `/etc/systemd/system/wordcraft-update.{service,timer}` | Deployed units, `root:root 0644`; the timer is enabled. |

Edit the files in `scripts/wordcraft/` and commit there, then deploy. The PKGBUILD is copied rather than symlinked because makepkg rewrites its `pkgver=` line on every build, which would dirty the repo. That line is only a placeholder; `pkgver()` computes the real value. From the repo root:

```sh
cp scripts/wordcraft/PKGBUILD ~/build/wordcraft-pkg/
d="$PWD/scripts/wordcraft"
pkexec sh -c "install -o root -g root -m 0755 '$d/wordcraft-update' /usr/local/bin/ &&
  install -o root -g root -m 0644 '$d/wordcraft-update.service' '$d/wordcraft-update.timer' /etc/systemd/system/ &&
  systemctl daemon-reload"
```

`wordcraft-update` is a bash script, so `.githooks/pre-commit` and CI lint it with `lint-bash.sh`. The PKGBUILD has no shebang, so the repo's tooling doesn't pick it up; lint it by hand with `shellcheck -s bash -e SC2034,SC2154 PKGBUILD` and `shfmt -ln bash -d PKGBUILD`. Check the units with `systemd-analyze verify`.

## Day-to-day commands

```sh
journalctl -u wordcraft-update                          # what each run did
systemctl list-timers wordcraft-update.timer            # next scheduled run
pkexec systemctl start wordcraft-update.service         # run an update now
pkexec systemctl disable --now wordcraft-update.timer   # stop automatic updates
pacman -Q wordcraft                                     # installed version
```

A run with nothing new logs `wordcraft-update: <version> already installed, nothing to do`. A real update logs `updating <old> -> <new>` and then `installed <new>`. Failures only appear in the journal; nothing notifies the desktop.

### Roll back a bad update

After a successful update, a run prunes `~/build/wordcraft-pkg/` down to the package it just installed and the one that was installed before it. Runs that exit early (nothing to do, `HOLD`, a failed install) and manual `makepkg` runs don't prune, so more files can be there. Pick the previous version by name from the `upgraded wordcraft (<old> -> <new>)` lines in `/var/log/pacman.log`, not by file age.

1. `pkexec pacman -U ~/build/wordcraft-pkg/wordcraft-<previous-version>-x86_64.pkg.tar.zst`
2. `touch ~/build/wordcraft-pkg/HOLD`. Without this, the next run sees the installed version is behind upstream and reinstalls the broken one.
3. Delete `HOLD` once upstream has a fix; the next run picks it up.

### Update by hand

```sh
git -C ~/build/wordcraft pull --ff-only
cd ~/build/wordcraft-pkg && makepkg -f && pkexec pacman -U "$(makepkg --packagelist)"
```

Don't do this while the timer's run is in progress (`systemctl is-active wordcraft-update.service`): the updater's lock only stops two of its own runs overlapping, not a manual `makepkg` in the same directory.

## How a run works

`wordcraft-update` runs as root. Everything that touches the user-owned build tree (`git`, sourcing the PKGBUILD, `makepkg` and its cargo build, pruning old packages) runs as `kartik` through `runuser` with an `env -i` environment. Root itself only does the script's own checks and locking, `pacman -Q`, and `pacman -U`.

1. Exits if `HOLD` exists, or if another run holds `/run/lock/wordcraft-update.lock`.
2. `git fetch`, retried up to 10 times at 60-second intervals, because a catch-up run fired on resume can start before Wi-Fi reconnects (`network-online.target` was reached at boot, so it doesn't wait). Then `git merge --ff-only`, which fails immediately and logs that updates are blocked if the clone has local edits or upstream diverged.
3. Sources the PKGBUILD as `kartik` and compares its `pkgver()` with `pacman -Q wordcraft`. If they match, it stops there.
4. `makepkg -f`, then checks the package path from `makepkg --packagelist` is a regular file owned by `kartik`.
5. Rechecks `HOLD` (it may have been created during an hour-long build), then `pacman -U`, retrying for up to 30 minutes only while pacman reports `unable to lock database`.
6. Deletes every `wordcraft-*.pkg.tar*` in the package's directory except the one just installed and the one it replaced.

The service runs at `Nice=19` with `CPUSchedulingPolicy=batch` and `IOSchedulingClass=idle`, has `ConditionACPower=true`, and allows four hours (`TimeoutStartSec=4h`) because a cold release build at idle priority can take over an hour. For scale: the initial cold `cargo build --release`, run by hand at normal priority on the Ryzen 9 7940HS, took 3m 38s. The first service run took about 4 seconds, because cargo found nothing to recompile.

The timer is `OnCalendar=*-*-1/2 03:30` with `Persistent=true` and up to 30 minutes of random delay. That's odd days of the month, so a month ending on the 29th or 31st is followed by a run on the 1st, the next day. `Persistent` catches up a run missed while the laptop was off or asleep. A run skipped for being on battery isn't retried until the next scheduled one.

## Design decisions

**pacman package, not `cargo install` or loose files in `/usr/bin`.** pacman tracks every installed file, so `pacman -Qkk wordcraft` can verify the install and `pacman -R` undoes it. Desktop, MIME and icon caches are refreshed by the pacman hooks shipped in `desktop-file-utils`, `shared-mime-info` and `gtk-update-icon-cache`. Those are listed as `depends` so the hooks are guaranteed present; upstream's `postinst.sh` for `.deb`/`.rpm` does the same refreshes by hand.

**Version per commit.** `pkgver()` produces `<Cargo.toml version>.r<UTC commit date YYYYmmddHHMM>.g<short hash>`, for example `0.8.0.r202610181831.gd82f17a`. `vercmp` orders it above both plain `0.8.0` and older commits, so every new upstream commit is an upgrade even when upstream's version number hasn't moved. The AppStream metainfo still gets the plain Cargo version, as upstream's `packaging/linux/package.sh` does. Its release date is the commit date rather than upstream's build date, so rebuilding the same commit doesn't move it.

**`!buildflags`.** CachyOS's `/etc/makepkg.conf.d/rust.conf` sets `RUSTFLAGS="-C opt-level=3 -C target-cpu=native"`. makepkg exporting that would make cargo rebuild the whole workspace instead of reusing `target/`. `options=('!buildflags')` unsets it, leaving optimisation to the workspace's own `[profile.release]` (opt-level 3, thin LTO).

**Root unit that builds as `kartik`.** Chosen by Kartik over a build-and-notify job (no root, manual install) and a sudoers `NOPASSWD` rule for `pacman -U`. The trade-off: root installs a package `kartik` built, so this trusts that account as much as sudo already does.

**systemd timer, not cron.** Arch doesn't install a cron daemon (`cronie` was absent), and `Persistent=true` catches up missed runs on a laptop, which cron doesn't.

## Dependencies

No packages were installed for this. The build needs Arch's `rust` (1.99.1 here; upstream requires 1.95+) and `base-devel`. Both were already installed earlier on 2026-10-18 for other reasons (`/var/log/pacman.log`), so on a fresh install add them first. At runtime, WordCraft loads windowing (X11/Wayland via `libxkbcommon`), the GPU (Vulkan through `nvidia-utils` and `vulkan-radeon`) and GTK 3 file dialogs dynamically; all of these were already present from the gaming and Plasma setup.

## Side effect: `.docx` default

Installing the package made WordCraft the default handler for `.docx`: `xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document` returns `ai.storyteller.wordcraft.desktop`. To change that, run `xdg-mime default <other>.desktop` with the same MIME type.

## State on 2026-10-18

Installed `wordcraft 0.8.0.r202610181831.gd82f17a-1` (upstream commit `d82f17a`). `pacman -Qkk wordcraft` reported 0 altered files. `wordcraft-cli --version` printed `0.8.0`, and the CLI saved its built-in sample as `.docx`, converted it to PDF and extracted its text. The desktop entry passes `desktop-file-validate`. The GUI window itself hasn't been opened yet.

The first `wordcraft-update.service` run, started by hand, went through the full path: it logged `updating 0.8.0-1 -> 0.8.0.r202610181831.gd82f17a-1`, built, installed, pruned and reported `Result=success`. That switched the package from its hand-built `0.8.0-1` to the per-commit version scheme, with no new upstream commit involved. A read-only simulation afterwards confirmed the next run would find upstream unchanged and exit with "nothing to do". Not yet exercised: a run where a new upstream commit is fetched, fast-forwarded and compiled. The first scheduled run was due Mon 2026-10-19 at about 03:36 BST.

The script, PKGBUILD and units passed `shellcheck`, `shfmt` and `systemd-analyze verify`, and went through four code-review passes. One known inefficiency was left as is: if a run builds a package but doesn't install it (`HOLD` appeared, or `pacman -U` failed for a reason other than the lock), the next run repeats `makepkg -f` rather than reusing the built package.
