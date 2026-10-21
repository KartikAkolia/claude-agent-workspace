# DeckCraft — source build on `asus-vivobook`

[DeckCraft](https://github.com/storytold/deckcraft) (a Rust presentation editor that reads and writes `.pptx`, from the same authors as WordCraft and PdfCraft) is built from source on `asus-vivobook` and installed as a local pacman package, so `pacman -R deckcraft` removes it cleanly. Upstream also publishes release binaries (AppImage, `.deb`, `.rpm`), but this build follows the same source-built, per-commit approach as the other two apps. It's kept up to date by `craft-update`, the shared updater for the *Craft apps. `docs/craft-update.md` covers that updater, rollback with `HOLD`, updating by hand, and the design decisions shared by all three packages. Set up on 2026-10-21. The State section says what was verified and what wasn't.

## Where things live

| Path | What it is |
|---|---|
| `~/build/deckcraft/` | Shallow clone of `storytold/deckcraft` (`main`). Cargo's `target/` stays here so rebuilds are incremental. |
| `scripts/deckcraft/PKGBUILD` (this repo) | The versioned original, derived from WordCraft's. Deploy it with `command cp scripts/deckcraft/PKGBUILD ~/build/deckcraft-pkg/`. |
| `~/build/deckcraft-pkg/` | makepkg's working directory: the deployed `PKGBUILD`, plus the built packages, `src/`, `pkg/` and an optional `HOLD` file. |
| `~/build/deckcraft-build.log` | Output of the first build. |

## What differs from the WordCraft package

**About dialog.** `build()` sets `DECKCRAFT_BUILD_SHA` to the clone's commit and `DECKCRAFT_BUILD_DATE` to its UTC commit date. Upstream's packaging uses today's date for the second, but the commit date means rebuilding the same commit produces the same About text.

**Dependencies.** DeckCraft plays audio through `cpal`, which links ALSA, so `alsa-lib` is a hard dependency. File dialogs go through `xdg-desktop-portal` (it uses `rfd` without GTK), so that replaces `gtk3`, with `xdg-desktop-portal-kde` as the optdepend for the Plasma backend. It doesn't link fontconfig or freetype and has no printing. `DECKCRAFT_WAYLAND=1` selects the native Wayland backend, as with WordCraft.

**Third-party licences.** Upstream's `licenses/` directory holds licence texts for vendored code, currently `pdf-writer/LICENSE-ICC.txt`. The package installs it under `/usr/share/licenses/deckcraft/` next to the project's own licences.

**No bundled fonts.** The build looks for an optional [craft-fonts](https://github.com/storytold/craft-fonts) checkout at `../craft-fonts` and logs `building without craft-fonts` when it isn't there. Upstream's README says DeckCraft then uses the system fonts. craft-fonts is public, so it could be cloned to `~/build/craft-fonts` and picked up by all three apps, but that isn't set up.

## Dependencies

No packages were installed for this. The build used Arch's `rust` 1.99.1 (upstream requires 1.95+) and `base-devel`, and every runtime `depends`, including `alsa-lib`, was already installed.

## Side effect: `.pptx` default

Installing the package made DeckCraft the default handler for PowerPoint files: `xdg-mime query default application/vnd.openxmlformats-officedocument.presentationml.presentation` returns `ai.storyteller.deckcraft.desktop`. Its desktop entry also claims `.potx`, `.ppsx` and its own `.deckcraft` format. To change the `.pptx` default, run `xdg-mime default <other>.desktop` with the same MIME type.

## State on 2026-10-21

Installed `deckcraft 0.9.0.r202610210740.g63831cd-1` (upstream `main` at `63831cd`; the v0.9.0 release is tagged at a different commit, `fe510bd`, so this isn't byte-for-byte the release build). The cold `makepkg -f` took 2m 29s, and the package is 26 MB. `pacman -Qkk deckcraft` reported 51 files and 0 altered. The desktop entry passes `desktop-file-validate`, and the metainfo passes `appstreamcli validate --no-net`.

`deckcraft-cli --version` prints `0.9.0`. The CLI created a presentation with `run --cmd 'slide.new=...' --save`, converted it to `.pptx`, read it back with `info`, rendered both slides to 1920×1080 PNGs with `render --all`, and exported it to PDF, whose text `pdfcraft-cli text` read back as `Smoke test`. The GUI window hasn't been opened yet.

The first `craft-update.service` run, started by hand after the migration, reported all three apps as `already installed, nothing to do` and `Result=success`.
