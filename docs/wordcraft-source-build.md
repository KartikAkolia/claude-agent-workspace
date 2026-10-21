# WordCraft — source build on `asus-vivobook`

[WordCraft](https://github.com/storytold/wordcraft) (a Rust word processor that reads and writes `.docx`) is built from source on `asus-vivobook` (Arch Linux with CachyOS repos, see `docs/archlinux-pacman-config.md`) and installed as a local pacman package, so `pacman -R wordcraft` removes it cleanly. It's kept up to date by `craft-update`, the shared updater for the *Craft apps. `docs/craft-update.md` covers that updater, rollback with `HOLD`, updating by hand, and the design decisions shared by all three packages. Until 2026-10-21 WordCraft had its own `wordcraft-update` script and timer. The State section below describes those as they were.

## Where things live

| Path | What it is |
|---|---|
| `~/build/wordcraft/` | Shallow clone of `storytold/wordcraft` (`main`). Cargo's `target/` stays here so rebuilds are incremental. |
| `scripts/wordcraft/PKGBUILD` (this repo) | The versioned original. Deploy it with `command cp scripts/wordcraft/PKGBUILD ~/build/wordcraft-pkg/`. |
| `~/build/wordcraft-pkg/` | makepkg's working directory: the deployed `PKGBUILD`, plus the built packages, `src/`, `pkg/` and an optional `HOLD` file. |

## Package details

`package()` mirrors the FHS staging in upstream's `packaging/linux/package.sh`. The AppStream metainfo gets the plain Cargo version, as upstream's script does, rather than the per-commit `pkgver`. Its release date is the commit date rather than upstream's build date, so rebuilding the same commit doesn't move it. `build()` sets `WORDCRAFT_BUILD_SHA` to the clone's commit, which the About dialog shows.

## Dependencies

No packages were installed for this. The build needs Arch's `rust` (1.99.1 here; upstream requires 1.95+) and `base-devel`. Both were already installed earlier on 2026-10-18 for other reasons (`/var/log/pacman.log`), so on a fresh install add them first. At runtime, WordCraft loads windowing (X11/Wayland via `libxkbcommon`), the GPU (Vulkan through `nvidia-utils` and `vulkan-radeon`) and GTK 3 file dialogs dynamically; all of these were already present from the gaming and Plasma setup.

## Side effect: `.docx` default

Installing the package made WordCraft the default handler for `.docx`: `xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document` returns `ai.storyteller.wordcraft.desktop`. To change that, run `xdg-mime default <other>.desktop` with the same MIME type.

## State on 2026-10-18

Installed `wordcraft 0.8.0.r202610181831.gd82f17a-1` (upstream commit `d82f17a`). `pacman -Qkk wordcraft` reported 0 altered files. `wordcraft-cli --version` printed `0.8.0`, and the CLI saved its built-in sample as `.docx`, converted it to PDF and extracted its text. The desktop entry passes `desktop-file-validate`. The GUI window itself hasn't been opened yet. The initial cold `cargo build --release`, run by hand at normal priority, took 3m 38s.

The first `wordcraft-update.service` run, started by hand, went through the full path: it logged `updating 0.8.0-1 -> 0.8.0.r202610181831.gd82f17a-1`, built, installed, pruned and reported `Result=success`. That switched the package from its hand-built `0.8.0-1` to the per-commit version scheme, with no new upstream commit involved.

## State on 2026-10-21

The timer's scheduled run at 09:08 BST did a real upstream update: `updating 0.8.0.r202610181831.gd82f17a-1 -> 0.9.0.r202610210639.ge05b7fe-1`, then `installed 0.9.0.r202610210639.ge05b7fe-1`. That was the first time the fetch, fast-forward, compile and install path ran for a new commit. Later that day `wordcraft-update` and its units were removed in favour of `craft-update`; see `docs/craft-update.md`.
