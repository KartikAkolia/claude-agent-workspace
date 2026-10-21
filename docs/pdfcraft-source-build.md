# PdfCraft — source build on `asus-vivobook`

[PdfCraft](https://github.com/storytold/pdfcraft) (a Rust PDF workbench from the same authors as WordCraft) is built from source on `asus-vivobook` and installed as a local pacman package, so `pacman -R pdfcraft` removes it cleanly. It's kept up to date by `craft-update`, the shared updater for the *Craft apps. `docs/craft-update.md` covers that updater, rollback with `HOLD`, updating by hand, and the design decisions shared by all three packages. Set up on 2026-10-21. The State section says what was verified and what wasn't.

## Where things live

| Path | What it is |
|---|---|
| `~/build/pdfcraft/` | Shallow clone of `storytold/pdfcraft` (`main`). Cargo's `target/` stays here so rebuilds are incremental, and `target/pdfcraft-models/` caches the OCR models. |
| `scripts/pdfcraft/PKGBUILD` (this repo) | The versioned original. Deploy it with `command cp scripts/pdfcraft/PKGBUILD ~/build/pdfcraft-pkg/`. |
| `~/build/pdfcraft-pkg/` | makepkg's working directory: the deployed `PKGBUILD`, plus the built packages, `src/`, `pkg/` and an optional `HOLD` file. |

## What differs from the WordCraft package

**OCR models.** Upstream's `packaging/linux/package.sh` ships two OCR models (`text-detection.rten`, `text-recognition.rten`) with their licences. The app looks for them at `<bin>/../share/pdfcraft/models`, so the package installs them at `/usr/share/pdfcraft/models`. `build()` runs `cargo xtask models` (spelled `cargo run --locked -p xtask -- models`, so it can't rewrite `Cargo.lock` and block the next fast-forward) into `~/build/pdfcraft/target/pdfcraft-models/`, which downloads a file (with `curl`) only when it's missing or its SHA-256 doesn't match upstream's `ATTRIBUTION.toml`. So a rebuild with nothing new doesn't touch the network. One gap: a model that upstream drops from the manifest would stay in that directory and keep shipping, without a credit in the regenerated `ATTRIBUTION.txt`. If that happens, `rm -r` the directory before the next build.

**File dialogs through the portal.** PdfCraft uses `rfd` without GTK, so file dialogs go through `xdg-desktop-portal`, which is a hard dependency here instead of `gtk3`. The portal also needs a desktop backend. On Plasma that's `xdg-desktop-portal-kde`, listed as an optdepend and already installed.

**Printing is optional.** The Print dialog calls CUPS's `lp` and `lpstat`, which on Arch come from `cups`. `cups` isn't installed, so Print offers only Save as PDF until it is. It's listed as an optdepend.

**No build SHA.** Unlike WordCraft and DeckCraft, PdfCraft reads no commit-hash env var at build time. Its only build-time variable is `PDFCRAFT_BUILD_LABEL`, which isn't set, so `--version` prints the plain upstream version.

**No bundled fonts.** `CRAFT_FONTS_DIR` is an optional font bundle that upstream's releases embed, and this build leaves it out. Without it, glyphs missing from the embedded fonts (Inter and egui's defaults) are drawn by one installed face chosen from a fixed list of known font paths (`crates/ui-egui/src/system_fonts.rs`), not by general fontconfig fallback. Noto Sans Arabic and Telugu are installed here, but no CJK font is, so Chinese or Japanese interface text will probably render as missing-glyph boxes. That hasn't been checked in the GUI.

## Dependencies

No packages were installed for this. The build used Arch's `rust` 1.99.1 (upstream requires 1.95+) and `base-devel`, both already present from the WordCraft build. All the runtime `depends` were already installed.

## Side effect: `.pdf` default

Installing the package made PdfCraft the default PDF handler: `xdg-mime query default application/pdf` returns `ai.storyteller.pdfcraft.desktop`. To change that back, run `xdg-mime default <other>.desktop application/pdf`.

## State on 2026-10-21

Installed `pdfcraft 0.10.1.r202610210759.g4164951-1` (upstream commit `4164951`). The cold `makepkg -f` took 4m 9s, and the package is 47 MB. A rebuild with nothing new took 2.9s and reused the cached models. `pacman -Qkk pdfcraft` reported 56 files and 0 altered. The desktop entry passes `desktop-file-validate`, and the metainfo passes `appstreamcli validate --no-net`.

`pdfcraft-cli --version` prints `0.10.1`. Run against `/usr/share/doc/speexdsp/manual.pdf`, the CLI's `info`, `text` and `render` all worked. An image-only page (that PDF's first page rendered to PNG) went through `batch --steps convert,ocr` and came back with its text recognised, which shows the installed models load. The GUI window hasn't been opened yet.

The installed package predates three PKGBUILD changes: the `xdg-desktop-portal-kde` optdepend, `curl` in makedepends, and the model cache. None of them changes what's installed. The optdepend reaches the package metadata with the next upstream commit's build.

PdfCraft first had its own `pdfcraft-update` script and timer. A manual run of it logged `0.10.1.r202610210759.g4164951-1 already installed, nothing to do`. It was replaced by `craft-update` the same day.
