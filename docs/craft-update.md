# craft-update — auto-update for the *Craft apps on `asus-vivobook`

WordCraft, PdfCraft and DeckCraft (all from [storytold](https://github.com/storytold)) are built from source on `asus-vivobook` and installed as local pacman packages. One root systemd timer pulls each upstream on odd days of the month and rebuilds and reinstalls only the apps with a new commit. Each app's own doc covers its package: `docs/wordcraft-source-build.md`, `docs/pdfcraft-source-build.md` and `docs/deckcraft-source-build.md`. This doc covers the shared updater. It replaced the per-app `wordcraft-update` and `pdfcraft-update` on 2026-10-21, when DeckCraft would otherwise have needed a third identical copy.

## Where things live

| Path | What it is |
|---|---|
| `~/build/<app>/` | Shallow clone of `storytold/<app>` (`main`). Cargo's `target/` stays here so rebuilds are incremental. |
| `~/build/<app>-pkg/` | makepkg's working directory: a deployed copy of the app's `PKGBUILD`, plus the built packages, `src/`, `pkg/` and an optional `HOLD` file. |
| `scripts/<app>/PKGBUILD` (this repo) | The versioned original of each PKGBUILD. |
| `scripts/craft-update/` (this repo) | The versioned originals: `craft-update`, `craft-update.service`, `craft-update.timer`. |
| `/usr/local/bin/craft-update` | Deployed updater, `root:root 0755`. |
| `/etc/systemd/system/craft-update.{service,timer}` | Deployed units, `root:root 0644`; the timer is enabled. |

The app list is the service's `ExecStart=/usr/local/bin/craft-update wordcraft pdfcraft deckcraft`. To add an app, clone it to `~/build/<app>`, put its PKGBUILD in `~/build/<app>-pkg/`, and append it there.

Edit the files in `scripts/` and commit there, then deploy. PKGBUILDs are copied rather than symlinked because makepkg rewrites their `pkgver=` line on every build; that line is only a placeholder, and `pkgver()` computes the real value. From the repo root (`command cp` because `cp` is aliased to `cp -i` here):

```sh
for a in wordcraft pdfcraft deckcraft; do command cp "scripts/$a/PKGBUILD" ~/build/$a-pkg/; done
d="$PWD/scripts/craft-update"
pkexec sh -c "install -o root -g root -m 0755 '$d/craft-update' /usr/local/bin/ &&
  install -o root -g root -m 0644 '$d/craft-update.service' '$d/craft-update.timer' /etc/systemd/system/ &&
  systemctl daemon-reload"
```

`craft-update` is a bash script, so `.githooks/pre-commit` lints it with `lint-bash.sh`. CI's `lint-bash.yml` lists it by name in its path filter, since it has no `.sh` extension. The PKGBUILDs have no shebang, so neither picks them up. Lint them by hand with `shellcheck -s bash -e SC2034,SC2154 PKGBUILD` and `shfmt -ln bash -d PKGBUILD`, and check the units with `systemd-analyze verify`.

## Day-to-day commands

```sh
journalctl -u craft-update                          # what each run did
systemctl list-timers craft-update.timer            # next scheduled run
pkexec systemctl start craft-update.service         # update every app now
pkexec systemd-run --wait --collect --unit=craft-update-manual \
  -p Nice=19 -p CPUSchedulingPolicy=batch -p IOSchedulingClass=idle \
  /usr/local/bin/craft-update pdfcraft              # update one app now
pkexec systemctl disable --now craft-update.timer   # stop automatic updates
pacman -Q wordcraft pdfcraft deckcraft              # installed versions
```

The script's own lines name the app (`craft-update: <app>: ...`); output from `git`, `makepkg`, cargo and `pacman` in between doesn't, so read a failure in context rather than grepping for the prefix. An app with nothing new logs `craft-update: <app>: <version> already installed, nothing to do`. A real update logs `updating <old> -> <new>` and then `installed <new>`. If any app fails, the run ends with `craft-update: failed: <apps>` and the unit's result is `failed`, but the other apps are still updated. Failures only appear in the journal; nothing notifies the desktop.

The one-app command runs `craft-update` in a transient unit with the timer's priority settings. Its log is under `journalctl -u craft-update-manual`, not `-u craft-update`. It doesn't check `ConditionACPower`. While it runs it holds the shared lock, so a scheduled run that starts then logs `another run is in progress, skipping` and skips every app until the next odd day.

### Roll back a bad update

After a successful update, a run prunes `~/build/<app>-pkg/` down to the package it just installed and the one that was installed before it. Runs that exit early (nothing to do, `HOLD`, a failed install) and manual `makepkg` runs don't prune, so more files can be there. Pick the previous version by name from the `upgraded <app> (<old> -> <new>)` lines in `/var/log/pacman.log`, not by file age.

1. `pkexec pacman -U ~/build/<app>-pkg/<app>-<previous-version>-x86_64.pkg.tar.zst`
2. `touch ~/build/<app>-pkg/HOLD`. Without this, the next run sees the installed version is behind upstream and reinstalls the broken one. `HOLD` pauses only that app.
3. Delete `HOLD` once upstream has a fix; the next run picks it up.

### Update by hand

```sh
git -C ~/build/<app> pull --ff-only
cd ~/build/<app>-pkg && makepkg -f && pkexec pacman -U "$(makepkg --packagelist)"
```

Don't do this while a run is in progress (`systemctl is-active craft-update.service`): the updater's lock only stops two of its own runs overlapping, not a manual `makepkg` in the same directory.

If upstream force-pushes `main`, the fast-forward fails, and every run logs `can't fast-forward ... updates blocked until fixed by hand` for that app. With no local edits to keep, recover with `git -C ~/build/<app> fetch --depth=1 origin main && git -C ~/build/<app> reset --hard FETCH_HEAD`.

## How a run works

`craft-update` runs as root. Everything that touches the user-owned build trees (`git`, sourcing a PKGBUILD, `makepkg` and its cargo build, pruning old packages) runs as `kartik` through `runuser` with an `env -i` environment. Root itself only does the script's own checks and locking, `pacman -Q`, and `pacman -U`.

The run exits at once if another run holds `/run/lock/craft-update.lock`. Then it takes the apps one at a time, in the order given, skipping any name without a `~/build/<app>-pkg/PKGBUILD`. Each app runs in its own subshell with `set -e`, so a failure ends only that app. For each app:

1. Stops if `HOLD` exists.
2. `git fetch`, retried up to 10 times at 60-second intervals, because a catch-up run fired on resume can start before Wi-Fi reconnects (`network-online.target` was reached at boot, so it doesn't wait). Once one app has given up, the rest try only once, so an outage costs about ten minutes, not ten per app. Then `git merge --ff-only`, which fails immediately and logs that updates are blocked if the clone has local edits or upstream diverged.
3. Sources the PKGBUILD as `kartik` and compares its `pkgver()` with `pacman -Q <app>`. If they match, it stops there.
4. `makepkg -f`, then checks the package path from `makepkg --packagelist` is a regular file owned by `kartik`.
5. Rechecks `HOLD` (it may have been created during an hour-long build), then `pacman -U`, retrying for up to 30 minutes only while pacman reports `unable to lock database`.
6. Deletes every `<app>-*.pkg.tar*` in the package's directory except the one just installed and the one it replaced.

The service runs at `Nice=19` with `CPUSchedulingPolicy=batch` and `IOSchedulingClass=idle`, has `ConditionACPower=true`, and allows eight hours (`TimeoutStartSec=8h`), because a cold release build at idle priority can take over an hour and a run can do three. For scale, at normal priority on the Ryzen 9 7940HS, cold builds took 3m 38s for WordCraft and 4m 9s for PdfCraft. A run with nothing to recompile takes seconds per app.

The timer is `OnCalendar=*-*-1/2 03:30` with `Persistent=true` and up to 30 minutes of random delay. That's odd days of the month, so a month ending on the 29th or 31st is followed by a run on the 1st, the next day. `Persistent` catches up a run missed while the laptop was off or asleep. A run skipped for being on battery isn't retried until the next scheduled one.

## Design decisions

**One updater for all the apps, not one per app.** WordCraft and PdfCraft each had their own copy of the same script and units. Kartik chose to merge them when DeckCraft would have made a third copy. That leaves one script to fix. Running the apps in sequence under one lock also means their builds never compete, which separate timers could only reduce by staggering their start times.

**pacman packages, not `cargo install` or loose files in `/usr/bin`.** pacman tracks every installed file, so `pacman -Qkk <app>` can verify the install and `pacman -R` undoes it. Desktop, MIME and icon caches are refreshed by the pacman hooks shipped in `desktop-file-utils`, `shared-mime-info` and `gtk-update-icon-cache`. Each PKGBUILD lists them as `depends` so the hooks are guaranteed present; upstream's `postinst.sh` for `.deb`/`.rpm` does the same refreshes by hand.

**Version per commit.** Each PKGBUILD's `pkgver()` produces `<Cargo.toml version>.r<UTC commit date YYYYmmddHHMM>.g<short hash>`, for example `0.8.0.r202610181831.gd82f17a`. `vercmp` orders it above both plain `0.8.0` and older commits, so every new upstream commit is an upgrade even when upstream's version number hasn't moved.

**`!buildflags`.** CachyOS's `/etc/makepkg.conf.d/rust.conf` sets `RUSTFLAGS="-C opt-level=3 -C target-cpu=native"`. If makepkg exported that, cargo would rebuild the whole workspace instead of reusing `target/`. `options=('!buildflags')` unsets it, leaving optimisation to each workspace's own `[profile.release]`.

**Root unit that builds as `kartik`.** Chosen by Kartik for WordCraft over a build-and-notify job (no root, manual install) and a sudoers `NOPASSWD` rule for `pacman -U`. The trade-off: root installs packages `kartik` built, so this trusts that account as much as sudo already does.

**systemd timer, not cron.** Arch doesn't install a cron daemon (`cronie` was absent), and `Persistent=true` catches up missed runs on a laptop, which cron doesn't.

## Known gaps

If a run builds a package but doesn't install it (`HOLD` appeared, or `pacman -U` failed for a reason other than the lock), the next run repeats `makepkg -f` rather than reusing the built package. The PKGBUILDs share their `_cargo_version`, `_commit_date` and `pkgver()` helpers by copy, not through a common file, so a fix to one has to be repeated in the others.

## State on 2026-10-21

Deployed `craft-update` and its units, enabled `craft-update.timer`, and disabled and deleted `wordcraft-update` and `pdfcraft-update` (scripts and units, from `/usr/local/bin`, `/etc/systemd/system` and this repo). `systemd-analyze verify` passes on the deployed units. The first scheduled run is due Fri 2026-10-23 at about 03:39 BST.

A `craft-update.service` run started by hand logged `already installed, nothing to do` for all three apps in order and reported `Result=success`. A direct run of `craft-update bogus deckcraft pdfcraft`, with `HOLD` in `~/build/deckcraft-pkg/`, skipped `bogus`, paused DeckCraft, still checked PdfCraft, ended with `failed: bogus` and exited 1. A failure inside an update was tested with a throwaway app, `crafttest`, whose `build()` runs `false`, using a local bare repo as its upstream (all removed afterwards). `craft-update crafttest pdfcraft` logged `updating none -> 1-1`, makepkg reported `A failure occurred in build()`, nothing was installed, PdfCraft was still checked, and the run exited 1 with `failed: crafttest`. Not yet exercised: a run that compiles and installs a real new commit, and the shortened retry after a failed fetch. The compile-and-install steps are unchanged from `wordcraft-update`, which did a real update earlier the same day.
