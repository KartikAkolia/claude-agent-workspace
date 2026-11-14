# Script audit, 2026-11-14

A skeptic-review audit of every tracked script in this repo, ranked by severity, and the fixes that followed. Scope was the 41 tracked script files outside the five ChrisTitusTech reference clones: the root lint/CI tooling, `.githooks/pre-commit`, everything under `scripts/`, `.claude/skills/quickshell/scripts/quickshell-qmllint`, the archived dashboard's `node --test` suite, and the `.github/workflows/` that call them. The gitignored subprojects (`estuary/`, `personal-website/`, `pi-homelab/` and the rest) weren't checked out on `asus-vivobook`, so they weren't reviewed.

Six read-only reviewer agents each took one area and were told to try to disprove every candidate finding before reporting it. Most findings were reproduced in scratch copies with stubbed commands; nothing ran privileged or against real hardware. Before the review, every lint gate and test suite was green: shellcheck, shfmt and `bash -n` on all 24 bash files, ruff, 97 Python tests and 48 JS tests. So nothing below is lint noise.

Severity follows one rubric throughout. **Critical** means data loss, system breakage or an exploitable security hole. **High** means wrong behaviour on a common path, a failure reported as success, or a gate that doesn't gate. **Medium** means an edge-case bug with a plausible real trigger, or misleading error handling. **Low** covers robustness and maintainability nits.

The Critical and High findings were fixed first, then the Medium and Low ones, by fix agents that each owned a disjoint set of files. Every fix was shown failing on an unfixed copy and passing afterwards, mostly through stubs, and each test suite gained tests that fail when the fix is reverted. "Fixed" below means fixed and verified that way, not exercised on real hardware or as root; the last section lists what still needs that.

| Severity | Found | Fixed |
| --- | --- | --- |
| Critical | 1 | 1 |
| High | 7 | 7 |
| Medium | 27 | 27 |
| Low | 33 | 33 |

## Critical and High

| ID | Severity | Location | Defect | Status |
| --- | --- | --- | --- | --- |
| TOOL-1 | Critical | `refresh-reference-clone.sh` | `rsync -a --delete` ran into any existing directory, so passing `.` or `docs` wiped the workspace including `.git/`, then reported "synced" (reproduced on a copy) | Fixed: `<local-dir>` must resolve to exactly the mirror its `<owner/repo>` maps to, checked before any download |
| TOOL-2 | High | `.githooks/pre-commit` | Took staged file names but linted the working-tree copies, so a stale broken blob, partial staging or a staged-then-deleted file committed with the hook passing | Fixed: the hook now lints an export of the index with the index's own tooling and configs, so it checks exactly what is committed, and unstaged edits neither hide nor block anything (pass 4 replaced an earlier refuse-while-dirty guard); links are checked against the index |
| TOOL-3 | High | `refresh-reference-clone.sh` | rsync's exit status was ignored, so a failed or partial sync printed "synced" and exited 0 | Fixed, along with diff's trouble status |
| SYS-1 | High | `scripts/sync-root-gtk-theme.sh` | `--apply` symlinked root's GTK config to user-writable files, so a `gtk-modules=` line could get a user-controlled `.so` loaded into root GParted on X11 | Fixed: root gets filtered, root-owned copies of the settings files only, read with Kartik's own privileges. Nothing else is copied from his home; a user-local theme, icon or cursor theme gets a printed install command (see the code review passes below) |
| SYS-2 | High | `scripts/install-brother-dcp-l2665dw.sh` | No distro check; on CachyOS Brother's installer falls through to `rpm -ihv --nodeps --replacefiles` as root, outside pacman | Fixed: refuses anything that isn't Debian-family with dpkg, and points to driverless IPP |
| FED-1 | High | `scripts/install-fedora.sh` | Both embedded Python editors ran as `python3 -`, putting the cwd first on `sys.path`, so a planted `shutil.py` in a shared cwd ran as root (reproduced) | Fixed: `python3 -I`, enforced by a static test over every `python3` call |
| FED-2 | High | `dwm-titus-debian-install.sh` | Installs `adw-gtk3`, which Debian doesn't package, so apt fails the whole line and `set -e` aborts the rest of the install | Fixed: dropped and listed under "Known gaps" |
| TUI-1 | High | `scripts/display-tui.sh` | Rate parser dropped any rate printed as `*+` (current and preferred), which is exactly this host's `179.98*+`, so picking the current resolution showed no rates | Fixed |

## Medium

| ID | Location | Defect | Status |
| --- | --- | --- | --- |
| TOOL-4 | `.github/workflows/lint-*.yml`, `list-lint-files.sh` | `mapfile < <(...)` hides a failing file lister, and the lint scripts exit 0 on zero files, so CI goes green while linting nothing | Fixed: listers fail on a git error or empty category, and CI reads NUL-separated lists under `-eo pipefail` |
| TOOL-5 | `.githooks/pre-commit`, `list-lint-files.sh` | `core.quotePath` C-quotes non-ASCII names, so such files are silently skipped by the hook and the bash sweep | Fixed: every list is built with `git ls-files -z` |
| TOOL-6 | `list-lint-files.sh`, `.githooks/pre-commit` | `':!.*'` excludes every `.md` under a dot-directory, so all 33 `.claude/skills/**` markdown files are never linted (they currently fail mdl) | Fixed: only `.git/` is excluded; the 13 failing skill files were reformatted without changing their wording |
| TOOL-7 | `.gitattributes` | Only `*.sh` is pinned to LF, so a Windows `autocrlf` checkout breaks the extensionless `.githooks/pre-commit` | Fixed: extensionless scripts and `*.py` pinned to LF, and a trailing CR is stripped before shebang matching |
| TOOL-8 | `.githooks/pre-commit` | A rename or delete never re-checks the files that link to it | Fixed: a commit with deletes or renames re-checks every tracked markdown file against the index |
| TOOL-9 | `check-markdown-links.py` | Titled, angle-bracket and reference-style links aren't checked, and inline links also resolve root-relative | Fixed: no new broken links surfaced across the repo |
| SYS-3 | `docs/btrfs-snapshots-snapper.md`, `scripts/setup-snapper.sh` | Doc says snapper is "working and verified" on this host, which is now ext4 with no snapper; under pkexec the non-root check passes trivially | Fixed: doc marked historical; script refuses non-btrfs or non-apt hosts and resolves the user from `PKEXEC_UID` |
| SYS-4 | `scripts/sync-root-gtk-theme.sh` | `set_kv` returns 1 on a missing file, aborting `--set` partway under `set -e`; mktemp+mv turns 0644 files into 0600 | Fixed |
| MC-1 | `scripts/minecraft-fabric/install.sh` | In system mode root writes a staged file inside a `minecraft`-owned dir, which a process running as `minecraft` could race with a symlink swap | Fixed: every write and rollback inside the tree runs as the owner |
| MC-2 | `scripts/minecraft-fabric/install.sh` (`peek`) | The sudo retry gets empty stdin, so `sha512sum -c` always fails and adoptable jars are rejected as "unmanaged" (fails safe) | Fixed |
| FED-3 | `scripts/install-fedora.sh` | A rerun after an interrupted first run leaves the stock kernel as default with no summary note, exit 0 | Fixed: the summary says the kernel isn't the default and gives the `grubby` command (it doesn't override a deliberate rollback) |
| FED-4 | `scripts/install-fedora.sh` | `--keep-selinux` still runs `setsebool -P domain_kernel_load_modules on` silently | Fixed: noted in the summary and documented |
| FED-5 | `scripts/install-fedora.sh` | A group SIGHUP/SIGTERM (dropped SSH) kills the log `tee`, so the summary is lost from the terminal and the log | Fixed |
| TUI-2 | `audio-tui.sh`, `display-tui.sh`, `webcam-tui.sh` | "Nothing found" msgboxes run inside `$(...)`, so they draw into the variable and the TUI looks frozen | Fixed in all three |
| TUI-3 | `scripts/start-canon-webcam.sh` | Ctrl-C sends gphoto2 SIGINT then SIGTERM 2 ms later (forced abort) and the script exits before ffmpeg finishes the recording | Fixed: children run under `setsid` joined by a FIFO, get one signal each, and are waited for |
| TUI-4 | `scripts/display-tui.sh` | `--auto` in position/mirror resets the output to its preferred mode and rate | Fixed |
| TUI-5 | `scripts/display-tui.sh` | "Detect" re-enables a panel that was turned off on purpose, and reports success even after xrandr failed | Fixed: asks first, places to the right, reports real results |
| TUI-6 | `scripts/audio-tui.sh` | The 150% cap applies only to "set"; "up" has no ceiling, and the menu highlight jumps back to "up" | Fixed |
| TUI-7 | `scripts/webcam-tui.sh` | Leading-zero input is parsed as octal, so `08` kills the TUI and `0250` sets 168 | Fixed |
| TUI-8 | `scripts/webcam-tui.sh` | Profile save ignores write failures and always says "Saved"; existing profiles are truncated without asking | Fixed |
| TUI-9 | `scripts/start-canon-webcam.sh` | `-d` doesn't change `video_nr`, and an already-loaded v4l2loopback makes modprobe a silent no-op | Fixed |
| TUI-10 | `scripts/start-canon-webcam.sh` | Waits for the node to exist, not for udev's uaccess ACL, so the first run after boot can fail "not writable" | Fixed: `udevadm settle` plus a bounded wait for write access |
| PY-1 | `scripts/sync-docs-to-trilium.py` | A trailing CR in `TRILIUM_ETAPI_TOKEN` raises an uncaught `ValueError` whose message prints the token | Fixed |
| PY-2 | `scripts/sync-docs-to-trilium.py` | The duplicate-note error says "delete one" without saying which is the managed original | Fixed |
| PY-3 | `scripts/test_sync_docs_to_trilium.py` | None of the three prune safety rails is tested; disabling any of them leaves the suite green | Fixed: each mutation now fails a test |
| PY-4 | `scripts/mathsisfun-algebra-*.py` | Failed fetches still land in `urls.txt`, and render prints 404/500 pages as "ok" | Fixed (a 304 from the profile's cache counts as success) |
| PY-5 | `scripts/mathsisfun-algebra-*` | URLs aren't normalised and the slug maps `/` and `-` alike, so pages duplicate or silently overwrite each other | Fixed |

## Low

| ID | Location | Defect | Status |
| --- | --- | --- | --- |
| TOOL-10 | `validate-config.sh` | Psych 4 safe-load rejects valid YAML anchors, and stderr is hidden | Fixed |
| TOOL-11 | `list-lint-files.sh` | `':!**/node_modules'` doesn't exclude nested `node_modules` contents | Fixed |
| TOOL-12 | `.githooks/pre-commit`, `list-lint-files.sh` | Shebang match misses `bash -e` / `env -S bash`; `#!/bin/sh` scripts aren't linted by any gate | Fixed: `#!/bin/sh` scripts are now linted too |
| TOOL-13 | `.github/workflows/` | Actions pinned to mutable tags, release binaries not checksum-verified, `mdl` unpinned | Fixed: actions pinned by SHA, shellcheck/shfmt downloads checked against sha256, `mdl=0.18.1` pinned |
| TOOL-14 | `refresh-reference-clone.sh` | `--delete` would remove gitignored local-only files inside a mirror | Fixed with TOOL-1 |
| SYS-5 | `scripts/install-c920-udev-rule.sh` | A failed `systemctl start` still ends "Done." with exit 0 | Fixed |
| SYS-6 | `scripts/disable-device-power-saving.sh` | `--preserve=all` copies old mtimes onto rewritten `/etc` files | Fixed (`--preserve=all --no-preserve=timestamps`; an explicit `context` fails hard without SELinux) |
| SYS-7 | `scripts/disable-device-power-saving.sh` | Completed runs keep a full `/boot` copy (~362 MB each, ~1.1 GB now) that nothing reads | Fixed for future runs; existing copies untouched |
| SYS-8 | `scripts/test_device_power_saving.py` | The signal test signals the `place()` subshell, never the main script's traps | Fixed |
| SYS-9 | `scripts/xppen-tablet/PKGBUILD` | Config dir is 0777 without the sticky bit (moot while the package is removed) | Fixed: the folder is now `root:wheel` 2775 and the files 0664, so only `wheel` members can write or rename them. The sticky 1777 tried first would have broken Qt's atomic saves (reproduced). GUI saving with the real driver is untested |
| MC-3 | `docs/minecraft-fabric-server.md` | Says `--yes` runs unattended, but several prompts have no flag; also first boot sends SIGTERM, not `stop` | Fixed |
| MC-4 | `.github/workflows/`, `scripts/minecraft-fabric/test_install.py` | No workflow runs this suite, and no system-mode path is exercised | Fixed: system-mode tests added and the suite runs in `lint-bash.yml` |
| MC-5 | `scripts/minecraft-fabric/install.sh` | Only firewalld/ufw are detected; an nftables drop policy gets no warning | Fixed |
| MC-6 | `scripts/minecraft-fabric/install.sh` | "Done" prints even if the JVM dies at once; the restart policy can loop forever | Fixed |
| MC-7 | `scripts/minecraft-fabric/install.sh` | sudo is always required, even in modes that never use it | Fixed |
| MC-8 | `scripts/minecraft-fabric/install.sh` | Every geyser rerun forces `auth-type: online`, overwriting a deliberate `offline` | Fixed |
| FED-6 | `scripts/install-fedora.sh` | The lock fd is inherited by children, including the upstream installers | Fixed for `as_user` children |
| FED-7 | `scripts/install-fedora.sh` | "dnf.conf tuned" is noted on every run; preflight output isn't logged | Fixed |
| FED-8 | `docs/install-fedora.md` | "Each default has an opt-out flag" is untrue for fstrim, dnf.conf and CRB/EPEL | Fixed (doc) |
| FED-9 | `dwm-titus-debian-install.sh` | Comments contradict the port doc (gamemode i386 packages, make targets) | Fixed |
| FED-10 | `scripts/test_install_fedora.py` | The `--dry-run` no-writes invariant is only tested through one step | Fixed: whole-script dry-run test |
| FED-11 | `scripts/install-fedora.sh` | `SUDO_USER=root` aborts even with `--no-cli-tools` | Fixed |
| TUI-11 | `scripts/display-tui.sh` | "Toggle" will turn off the last active output, with no revert timer | Fixed (last-output guard; no revert timer, as whiptail has no timeout) |
| TUI-12 | `scripts/start-canon-webcam.sh` | An existing `-r` file makes ffmpeg exit 0 immediately and the script reports "Stopped." | Fixed |
| TUI-13 | `scripts/audio-tui.sh` | pactl failures are painted over by the next screen | Fixed |
| TUI-14 | `scripts/webcam-tui.sh` | "Preset applied" is shown even after a failed set | Fixed |
| TUI-15 | `scripts/export-windows-fonts.ps1`, `docs/canon-4000d-usb-webcam.md` | A trailing separator puts the zip inside the folder; the Canon doc is out of date with the script and host | Fixed: parse check and PSScriptAnalyzer 1.25.0 clean under PowerShell 7.7.0; the path handling was run end to end on Linux with a fake font folder |
| PY-6 | `scripts/mathsisfun-algebra-merge.sh` | Missing PDFs are dropped silently with exit 0; "pages" is really a file count | Fixed (`--allow-missing` to merge anyway) |
| PY-7 | `scripts/sync-docs-to-trilium.py` | Protected notes return the title "[protected]", so the run PATCHes and aborts | Fixed: skipped with a warning |
| PY-8 | `scripts/sync-docs-to-trilium.py` | A lost create-note response leaves an orphan note and a duplicate on the next run | Fixed: client-chosen `noteId`, looked up on an ambiguous failure |
| PY-9 | `scripts/mathsisfun-algebra-render.py` | An empty `urls.txt` or a first-URL timeout crashes before any PDF | Fixed |
| PY-10 | `scripts/test_sync_docs_to_trilium.py`, dashboard tests | Two test names don't match what they test; dead setup code | Fixed |
| JS-1 | `productivity/dashboard-archive/` tests | Click tests fabricate targets instead of reading the template's `data-action` attributes (retired archive) | Fixed in the tests only; `dashboard.html` unchanged |

## What held up

The reviewers spent as much effort ruling things out as finding them. The Trilium sync's prune logic survived every scenario thrown at it: it deleted only stale doc and folder notes it owned, and refused clones and folders holding live docs. The Minecraft installer verifies every mod's SHA-512, downloads over HTTPS only, and has no path that deletes world data. `install-fedora.sh`'s nested-`if` gate genuinely gates. Its `.bashrc` and `dnf.conf` editors handle symlinks, ownership, concurrent changes and interruption correctly. `lint-versions.sh` sync mode doesn't corrupt `.lint-versions`. No script has a command-injection path from device names, hostnames or filenames.

## Code review passes

After the fixes, the whole diff went through eight xhigh `/code-review` passes, each followed by fixes and a full re-validation. At Kartik's direction, pass 8's fixes were the last round before everything was merged, so they were validated but not independently re-reviewed. Pass 1 found 15 issues. The worst was that the Trilium sync died on every run, because it parsed the mirror list out of `list-lint-files.sh` and the tooling rewrite had renamed that variable. The five mirrors now live in one file, `reference-clones.tsv`, which the lint tooling, the refresh script and the Trilium sync all read. Pass 1 also showed the SYS-1 theme filter could be bypassed by splitting a GTK2 statement across lines or by a CSS `@import url(file:///…)`.

Pass 2 found three more ways round the theme filter: a symlink hiding a file from the scan, an `include` of a file whose name isn't scanned, and a symlink swapped in between the check and the copy. So `sync-root-gtk-theme.sh` stopped trying to recognise dangerous themes. It no longer copies user-local GTK themes into `/root`, and if one is configured it says to install it system-wide. Every read of Kartik's files (settings, icon and cursor themes) now runs with his own privileges, so root only ever gets content his account could already read. Icon copies are capped at 500 MiB, and `--check` compares manifests instead of building a second copy.

Pass 3 found 14 issues. The serious one: the old symlink version had also linked `/root/.themes` and `/root/.local/share/themes` into Kartik's home, and nothing removed those links. Now `--check` reports them as UNSAFE and `--apply` removes them. The pass also found:

- a failed icon read deleted root's previous copy;
- a file-mode rule reported permanent drift for some files;
- the Brother installer counted a queue left from an earlier run as success;
- setting a mode on a display that was off stacked it on top of the main one;
- the webcam TUI rejected valid int64 values;
- the XP-Pen sticky-bit fix would have broken Qt's atomic saves.

The PowerShell font exporter, never linted before, was linted with PSScriptAnalyzer and run under PowerShell 7.7.0. The power-saving tests now run in CI.

Pass 4 found 15 issues. The largest:

- `sync-root-gtk-theme.sh` sourced a user-writable helper library on its root path. It's now loaded only on the user-side `--pick`, and a root run warns, with the root-owned install route, whenever the script or a directory above it is writable by a non-root user.
- The pre-commit hook was rebuilt to lint an exported copy of the index, which ended its "refuse while any config is dirty" guard.
- The mirror list gained an owner allowlist, and the refresh script a large-change safety net.

Pass 5 found 11 issues. One was Critical, and the reviewer reproduced it: a symlink named after the script's marker file, placed in `~/.icons`, made `--apply` write as root to wherever the link pointed. A link to `/etc/ld.so.preload` would have turned that into code execution as root. The marker name is now excluded on extract and the marker is created with no-follow semantics, and every root-side write was audited for the same class of bug. The pass also made three changes:

- `--set` and `--pick` now refuse to run as root;
- suggested commands are shell-quoted;
- the Trilium sync and the hook now read the mirror list through the one validator in `list-lint-files.sh`.

Pass 6 found 11 issues. Three were serious, all in `sync-root-gtk-theme.sh`: its legacy cleanup could `rm -rf` through a symlinked `/root/.local` into Kartik's own themes, it deleted mixed directories instead of backing them up, and a newline in a link target slipped past the in-tree check. With Kartik's agreement the script was then simplified (1445 to 1004 lines). Root now gets only the filtered settings files and copies nothing else from his home, so all of the copy, manifest, prune and marker machinery, where nearly every serious finding of passes 2 to 6 lived, is gone. The legacy cleanup never deletes recursively: it unlinks symlinks, renames real directories aside, and refuses a symlinked ancestor. From here the loop runs until a pass has no Critical or High findings, and the Low items left are logged as follow-ups.

Pass 7 found 8 issues and no Critical. The most serious was that the install command printed for a user-local theme could put a symlink into `/usr/local/share/themes` pointing back into Kartik's home, if the theme directory was itself a symlink. The command is now withheld, with an explanation, for any theme that is a symlink or links outside itself. The pass also fixed four things: a test-only `ROOT_HOME` could leak into a real root run, renamed or deleted files could skip CI's link check, `SPEC.md` still said the repo has no tests, and two doc lines described older behaviour.

Pass 8 found 11 issues. The serious one: the install command printed for a user-local theme still passed an absolute symlink that points back into the theme, and any check would be stale by the time the command was pasted anyway. So the script now prints no root command for user-local trees at all; it names the path and says to install it system-wide by a trusted route. It also stopped treating root's own `/root/.icons` as a leftover, takes the user's home from passwd, and reports a vanished Brother queue as a failure. Three other areas were fixed: the Canon bridge now stops gphoto2 first and lets ffmpeg finish on EOF, so neither can kill the other mid-shutdown; `display-tui.sh` ignores modes no output owns and no longer needs `grep`; and the XP-Pen package's pacman scriptlet applies the new permissions on upgrade.

The other review fixes:

- Moving a mirrored display no longer leaves it stretched.
- The TUIs share one helper library, `scripts/lib/tui.sh`, and a test fails if one grows its own copy.
- The Canon bridge's children get a parent-death signal, so they stop if the script is killed outright.
- Both the nftables warning and the restart-limit text are now accurate.
- A `--dry-run` summary marks every note `[would]`.
- A second Fedora run can't write into the first run's log.
- snapper's `ALLOW_USERS` follows the invoking user.
- The pre-commit hook now lints an export of the index with the committed linter scripts and configs, so it checks exactly what's being committed, and an unrelated unstaged edit no longer blocks a commit. It also re-lints markdown when the mdl pin changes.
- Refresh exclusions survive glob characters in names.
- The YAML validator rejects undefined aliases and Ruby object tags.

Two findings were left as they are, on purpose. The edits to `productivity/dashboard-archive/` are test-only, and `dashboard.html` is untouched. AGENTS.md says not to change that archive without being explicitly asked. After seeing this audit, with JS-1 and JS-2 listed under Low at that path, Kartik asked: "after that, fix the medium and all low issues too". When review pass 4 asked again, he explicitly confirmed keeping these test fixes (2026-11-14). His untracked `docs/rsync-iso-copy.md` predates this work and is out of scope at his request. A reviewer's arithmetic for the systemd restart window, about 140 s, miscounts by one cycle: systemd refuses a start once more than `StartLimitBurst` starts fall within the interval, which makes it about 110 s.

## Still needs Kartik

These need root, hardware or a platform this session didn't have.

1. The root GTK sync is done on `asus-vivobook` (2026-11-14). `pkexec scripts/sync-root-gtk-theme.sh --check` found root's three GTK settings files missing and no legacy links, `--apply` wrote filtered copies with `gtk-modules` left out, and a second `--check` reported all three `ok`. Its one NOTE was the user-local `Nordic-cursors` cursor theme, so root apps use the default cursor until that theme is installed system-wide by a route you trust (the distro or AUR package, or a copy you've reviewed into `/usr/local/share/icons`). Still to do: relaunch GParted to confirm it looks themed, and run the same `--check`, `--apply`, `--check` once on `dell-optiplex`.
2. Optionally reclaim the `/boot` copies earlier `disable-device-power-saving.sh` runs left under `/var/lib/device-power-saving/run.*` (about 1.1 GB). Remove `boot/` only from runs marked `complete` or `undone`, never from one that still has a `pending` file.
3. Root GTK apps on X11 also read XSETTINGS from the user's `xsettingsd`, so a process running as kartik could probably still inject a GTK module that way. No file under `/root` can close that; it's a property of running root GUI apps in a user's X session.
4. These were verified only with stubs: the Canon 4000D shutdown and udev timing, the C920 udev helper, the audio, display and webcam TUIs against real PipeWire, X and cameras, Brother's driverless `lpadmin` route, and the Minecraft and Fedora installers as root. `scripts/export-windows-fonts.ps1` was linted and run under Linux PowerShell 7.7.0 with a fake font folder, but not on Windows against real font folders.
5. The pre-commit hook now lints the staged copy of every file, not the working tree. A failed commit is fixed by fixing the file *and* staging it again; editing it without `git add` changes nothing the hook sees.
6. `check-markdown-links.py` checks markdown links of any target type, but backtick paths only when they end in `.md`, so deleting a script that a doc names only in backticks or a code block (e.g. `bash scripts/setup-snapper.sh`) isn't caught. Widening it risks false positives on illustrative paths; left as a Low follow-up.
7. When the hook bumps shellcheck or shfmt in `.lint-versions` to a version with no hand-pinned sha256 in `.github/workflows/lint-bash.yml`, CI verifies the download against GitHub's own release-asset digest and warns that a pin should be added. Releases uploaded before mid-2025 carry no digest, so those versions still need a hand pin. mdl's gem dependencies aren't pinned.
8. On the Windows clone, files already checked out with CRLF stay that way until checked out again, e.g. `git checkout -- .githooks/pre-commit` once nothing there is uncommitted.
9. The updated workflows haven't run on GitHub yet; their steps were simulated locally. Watch the first CI run after pushing.
