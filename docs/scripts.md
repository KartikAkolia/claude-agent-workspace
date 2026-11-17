# Scripts index

Every script this repo tracks outside the five reference clones, with what it does, the doc that explains it, its tests and who it runs as. Since 2026-11-15 the scripts carry only a short header plus a `# Docs:` line pointing at their doc. The exceptions are the two-line `xppentablet` wrapper, the PowerShell script, whose comment-based help is its doc, and the unittest suites, which appear in the Tests column instead of as rows. Design reasons, contracts, safety rules and operating steps live in the linked docs, not in the code. When you add a script, add a row here and a `# Docs:` line to its header. If no existing doc fits it, write one.

## Host setup and installers

| Script | What it does | Doc | Tests | Runs as |
|---|---|---|---|---|
| `scripts/install-fedora.sh` | Post-install setup for Fedora and EL10 (Rocky, AlmaLinux, CentOS Stream, RHEL 10): DNF tuning, CRB/EPEL, toolchain, CachyOS kernel, SELinux and firewalld off, guest agent, OpenJDK and shell tools | [install-fedora.md](install-fedora.md) | `scripts/test_install_fedora.py` | root (`sudo`); `--dry-run` works as a user |
| `dwm-titus-debian-install.sh` | Installs the Debian apt equivalents of dwm-titus's Fedora package profiles (gaming excepted) before dwm is built with `sudo make install` | [dwm-titus-debian-port.md](dwm-titus-debian-port.md) | none | user; apt through `sudo` |
| `scripts/setup-snapper.sh` | Historical: Snapper on a Debian Btrfs root with a `root` config, non-root `ALLOW_USERS` and the timeline, cleanup and boot timers | [btrfs-snapshots-snapper.md](btrfs-snapshots-snapper.md) | none | user, or root through `sudo`/`pkexec`; installs through `sudo` |
| `scripts/disable-device-power-saving.sh` | Turns off USB/PCI runtime PM, PCIe ASPM and NVMe, HDA, NVIDIA and Wi-Fi power saving on `asus-vivobook` (Arch, GRUB, mkinitcpio), with a recoverable backup per run, `--undo` and `--recover` | [device-power-saving.md](device-power-saving.md) | `scripts/test_device_power_saving.py` | root (re-runs itself through `sudo`) |
| `scripts/device-power-saving-config.py` | Helper for the script above: edits the GRUB command line only as a literal, and checks effective modprobe options and the generated `grub.cfg` | [device-power-saving.md](device-power-saving.md) | `scripts/test_device_power_saving.py` | root, called by the script above |
| `scripts/sync-root-gtk-theme.sh` | Gives root filtered, root-owned copies of the user's GTK appearance settings so pkexec'd apps such as GParted match; also lists, sets or picks the user's own GTK theme | [gparted-root-theme-fix.md](gparted-root-theme-fix.md) | `scripts/test_tui_lib.py` (non-root paths) | user for `--list`, `--set` and `--pick`; the root modes such as `--apply` re-run themselves through `sudo`, or run them with `pkexec` |
| `scripts/minecraft-fabric/install.sh` | Installs or updates a standalone Fabric Minecraft server, optionally with Geyser and Floodgate, run as a systemd user unit, a hardened system unit or from `start.sh` | [minecraft-fabric-server.md](minecraft-fabric-server.md) | `scripts/minecraft-fabric/test_install.py` | user; `sudo` only for a system unit, packages and the firewall |
| `scripts/rss-stack.sh` | Installs and runs a self-hosted RSS stack with Docker Compose (FreshRSS, RSS-Bridge and an optional cloudflared tunnel), with `update`, `backup`, `status` and `credentials` commands | [rss-stack-pi.md](rss-stack-pi.md) | none | root (`sudo`); `DRY_RUN=1 install` works as a user; for rootless Docker, `sudo --preserve-env=DOCKER_HOST` |
| `scripts/xppen-tablet/PKGBUILD` | Repackages XP-Pen's prebuilt Linux driver as the local pacman package `xppen-tablet`, with a seat-ACL udev rule and a `wheel`-writable settings folder | [xppen-tablet/README.md](../scripts/xppen-tablet/README.md) | none | `makepkg` as a user, `pacman -U` as root |
| `scripts/xppen-tablet/xppen-tablet.install` | pacman scriptlet that reapplies the settings folder's `root:wheel` 2775/0664 permissions on every install and upgrade | [xppen-tablet/README.md](../scripts/xppen-tablet/README.md) | none | root, under pacman |
| `scripts/xppen-tablet/xppentablet` | `/usr/bin` wrapper that runs `/usr/lib/pentablet/PenTablet.sh` by its real path | [xppen-tablet/README.md](../scripts/xppen-tablet/README.md) | none | desktop user |
| `scripts/export-windows-fonts.ps1` | Copies the fonts from a Windows install (system, per-user and Office cloud fonts) into a folder and a zip for use on Linux | its comment-based help (`Get-Help`) | none | Windows user, no admin |

## Desktop and hardware

| Script | What it does | Doc | Tests | Runs as |
|---|---|---|---|---|
| `scripts/audio-tui.sh` | whiptail menu over pactl: default devices, per-app stream routing, volume and mute (capped at 150%), card profiles and ports | [desktop-tuis.md](desktop-tuis.md) | none | desktop user |
| `scripts/display-tui.sh` | whiptail menu over xrandr on X11: resolution and refresh rate, primary display, layout, mirroring, rotation, displays on or off | [desktop-tuis.md](desktop-tuis.md) | none | desktop user |
| `scripts/webcam-tui.sh` | whiptail menu over v4l2-ctl: camera info, exposure and focus presets, editing any control, defaults and saved profiles | [desktop-tuis.md](desktop-tuis.md) | none | desktop user |
| `scripts/lib/tui.sh` | Shared whiptail and number helpers, sourced by the three TUIs and `sync-root-gtk-theme.sh --pick`; not run on its own | [desktop-tuis.md](desktop-tuis.md) | `scripts/test_tui_lib.py` | sourced |
| `scripts/dwm-external-only.sh` | Under dwm on `asus-vivobook`, keeps the external HDMI monitor at 1920x1080 max refresh as the only display while connected and re-lights the internal panel on unplug; `watch` polls RandR because the NVIDIA port sends no hotplug uevent. `scripts/dwm-external-only.desktop` starts it at login | [dwm-external-display.md](dwm-external-display.md) | none | desktop user, as a systemd user unit from XDG autostart |
| `scripts/start-canon-webcam.sh` | Bridges a Canon EOS DSLR's USB live view onto a v4l2loopback webcam (gphoto2 to ffmpeg to `/dev/videoN`), optionally recording it | [canon-4000d-usb-webcam.md](canon-4000d-usb-webcam.md) | none | user; loads v4l2loopback through `sudo` when needed |
| `scripts/install-c920-udev-rule.sh` | Installs a udev rule, a `c920-settings@.service` template and a helper so a Logitech C920 gets manual exposure and autofocus off on every plug-in, then applies them now | [logitech-c920-webcam.md](logitech-c920-webcam.md) | none | user; every install step through `sudo` |
| `scripts/c920-apply-settings.sh` | Writes the C920 "stable" v4l2 settings to one capture node and re-applies them until they hold | [logitech-c920-webcam.md](logitech-c920-webcam.md) | none | root, under `c920-settings@videoN.service` |
| `scripts/install-brother-dcp-l2665dw.sh` | Installs Brother's CUPS driver for the DCP-L2665DW through its pinned `linux-brprinter-installer` and verifies a matching queue afterwards (Debian/Ubuntu only) | [brother-dcp-l2665dw-printer.md](brother-dcp-l2665dw-printer.md) | none | user in a real terminal; installer and `lpadmin` through `sudo` |

## Data and documents

| Script | What it does | Doc | Tests | Runs as |
|---|---|---|---|---|
| `scripts/mathsisfun-algebra-discover.py` | Crawls one mathsisfun.com section breadth-first and prints every page that fetched, one URL per line | [mathsisfun-pdf-scrape.md](mathsisfun-pdf-scrape.md) | none | user |
| `scripts/mathsisfun-algebra-render.py` | Renders each URL in `urls.txt` to an A4 PDF through one persistent headless Chrome profile | [mathsisfun-pdf-scrape.md](mathsisfun-pdf-scrape.md) | none | user |
| `scripts/mathsisfun-algebra-merge.sh` | Merges the per-page PDFs into one book in `urls.txt` order, refusing if any is missing unless `--allow-missing` is given | [mathsisfun-pdf-scrape.md](mathsisfun-pdf-scrape.md) | none | user |
| `scripts/sync-docs-to-trilium.py` | Mirrors `docs/` into Trilium as read-only notes; `--prune` removes notes for deleted files | [repo-tooling.md](repo-tooling.md) | `scripts/test_sync_docs_to_trilium.py` | user, with an ETAPI token |

## Repo tooling

| Script | What it does | Doc | Tests | Runs as |
|---|---|---|---|---|
| `lint-markdown.sh` | Full local lint sweep: mdl and link checks on markdown, config parsing, and the bash and Python linters over every tracked file | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, CI |
| `lint-bash.sh` | shellcheck, `shfmt -d` and `bash -n`/`sh -n` on the given shell scripts, at the versions in `.lint-versions` | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, hook, CI |
| `lint-python.sh` | `ruff check` and `ruff format --check` through uvx at the pinned ruff version | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, hook, CI |
| `validate-config.sh` | Checks that JSON and YAML files parse (Python `json.tool`; Ruby Psych with only plain types, dates and symbols) | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, hook, CI |
| `list-lint-files.sh` | Lists the tracked files each lint category applies to, skipping the reference clones; sourced, provides the shared `llf_*` helpers | [repo-tooling.md](repo-tooling.md) | `scripts/test_sync_docs_to_trilium.py` | user, hook, CI |
| `lint-versions.sh` | Reads and updates `.lint-versions`; the hook's sync mode follows newer installed shellcheck/shfmt unless a line is held | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, hook, CI |
| `.githooks/pre-commit` | Lints exactly what a commit contains by exporting the index and running the index's own tooling over the staged files | [repo-tooling.md](repo-tooling.md) | none | git, on commit |
| `check-markdown-links.py` | Flags markdown links and backticked `.md` paths that name missing local files | [repo-tooling.md](repo-tooling.md) | none; CI runs it | user, hook, CI |
| `refresh-reference-clone.sh` | Resyncs one ChrisTitusTech mirror from its GitHub tarball, refusing a mismatched directory or a large change without `--force-large-change` | [repo-tooling.md](repo-tooling.md) | none | user, on Kartik's request only |
| `.claude/skills/quickshell/scripts/quickshell-qmllint` | Runs qmllint on a Quickshell config with Qt's QML roots and lint-only `qmldir` maps for local `qs.*` imports | [linting.md](../.claude/skills/quickshell/references/linting.md) | none | user |
