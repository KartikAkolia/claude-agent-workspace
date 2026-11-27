# mdview

mdview is a small GTK4 Markdown viewer, written in Rust, that takes on the system GTK theme (Nordic, Papirus-Dark and Noto Sans on `asus-vivobook`). It lives in `mdview/`. The design, the decisions behind it and the pitfalls the skeptic reviews found are in [mdview-plan.md](mdview-plan.md); read that before changing it.

Status, 2026-11-27: Phase 1 (the viewer) is built and checked on `asus-vivobook`. Editing, saving and find come in Phase 2, links and the desktop entry in Phase 3, and autosave after that.

## Build and run

```bash
cd mdview
cargo build --release
./target/release/mdview ../docs/archival.md     # or several files; each gets a window
cargo run -- ../AGENTS.md                       # debug build
```

It needs GTK 4.12 or newer with its development files: on Arch, the `gtk4` package has them; on Debian or Ubuntu, `libgtk-4-dev`. There are two crates, `gtk4` (feature `v4_12`) and `pulldown-cmark` (no default features), and the profiles are copied from `minecraft-tui/Cargo.toml`. `cargo build --profile dist` gives the smallest binary, in `target/dist/`.

The release build's app id is `io.github.kartikakolia.mdview`, and a debug build's is that plus `.Devel`. Launching a second copy with files hands them over D-Bus to the copy already running, which opens each in its own window (reusing an empty one) or focuses the window already showing it. The separate debug id keeps `cargo run` from handing its files to an installed copy.

## Using it

| Key or action | Does |
| --- | --- |
| Ctrl+O, or the header bar's open button | Open a Markdown file in this window, through the desktop's file dialog |
| Drop a file on the window | Open it in this window |
| Ctrl+W | Close the window |
| Ctrl+Q | Quit |

Only `.md` and `.markdown` files open, in any case (`README.MD` too). mdview refuses, with a dialog naming the reason, anything that:

- isn't a regular file, after following symlinks (a directory, a FIFO, a device such as `/dev/zero`); a file whose type a gvfs backend leaves unknown is let through to the capped read
- is over 8 MiB
- holds a NUL byte
- isn't valid UTF-8

A refused file never replaces the document already showing.

What renders: CommonMark, plus GFM tables, task lists and strikethrough, and YAML front matter as a dimmed block. Raw and inline HTML, HTML comments, math and footnote syntax show as literal text, and an image shows as its alt text in italics. mdview never loads image files or touches the network. Link clicks do nothing until Phase 3.

## How it follows the theme

There are no colour literals. `mdview/style.css` uses only named colours from Nordic's gtk-4.0 sheet (`theme_fg_color`, `insensitive_fg_color`, `borders`). It loads at `STYLE_PROVIDER_PRIORITY_USER + 1`, because KDE's `~/.config/gtk-4.0/gtk.css` imports Nordic at USER priority and would otherwise override it.

The rendered view is one read-only `TextView`. The reading column is centred by a tag spanning the whole text, not by the view's own margins, which would count toward the window's minimum width and stop it shrinking. Text tags take colour values rather than CSS. So the window keeps three hidden probe widgets and copies their computed colours into the tags: a `LinkButton` for the theme's link colour (Nordic has no named one), and two labels that `style.css` gives the dim and tint colours. On 2026-11-27 they returned `rgb(94,129,172)`, `rgb(142,149,164)` and `rgba(216,222,233,0.07)`, which are Nordic's own values.

Tables are `Grid`s anchored in the text, sized on every width change to their natural width (capped at the reading column) and to the height their cells wrap to at that width. A `TextView` would otherwise give an anchored widget its minimum size. Cells wrap only between words, so a table that can't fit even then (a 30-column one, say) scrolls sideways inside the column rather than breaking its cells into single characters. A table's forced minimum width counts toward the window's, so it is set one indent step under the room the table has: a full-width table stops that step short of the column's right edge, and in exchange the window can always be narrowed, a step per layout pass.

A theme or font change needs a restart: GTK4 reads the user `gtk.css` once (GNOME/gtk#3409), and the tag colours and the column's measurements are taken when a document is shown.

## Code

| File | Holds |
| --- | --- |
| `src/main.rs` | The application, its app id, accelerators and the stylesheet |
| `src/render.rs` | Markdown to text, styled character ranges and tables: pure Rust, no GTK, and most of the tests |
| `src/file.rs` | The strict checks and the read |
| `src/window.rs` | Windows, the rendered view, filling its buffer, tables, the centred column, open and drop |
| `style.css` | The only stylesheet |

## Build time

Measured on `asus-vivobook` (16 threads, Rust 1.100.0) on 2026-11-27, from `cargo clean`:

| Build | Time |
| --- | --- |
| Cold dev build | 30.6 s |
| Dev rebuild after an edit | 0.24 s |
| Cold release build | 37.6 s |
| Release rebuild after an edit | 0.16 s |

The release binary is 967,856 bytes. Nearly all the cold time is gtk-rs's serial chain (glib, gio, pango, gdk4, gsk4, gtk4); none of it can be trimmed from this side, as the plan's Non-functional section records.

## Checks

`cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` and `cargo test --locked` (28 unit tests, in `render.rs` and `file.rs`). The pre-commit hook runs the first two whenever a commit touches `mdview/`, and `.github/workflows/mdview.yml` runs all three. CI is a single job with no release artifact: a GTK app is tried on the desktop, not downloaded from a run. [repo-tooling.md](repo-tooling.md) covers the hook and the workflow.

Phase 1 manual check on `asus-vivobook`, KDE Plasma on Wayland, 2026-11-27, all passed:

- The window uses Nordic: header bar, window buttons, Noto Sans, dark mode, and the empty state.
- `docs/archival.md` (154,149 characters) renders in 4 ms and fills the view in 13 ms in a debug build, with no stall.
- A fixture with every block type renders correctly: front matter, headings, inline styles, a hard break, nested and numbered lists, task boxes, a quote, a code block, a wide and a narrow table, a rule, HTML and an image's alt text.
- A FIFO, a symlink to `/dev/zero`, a NUL file, a Latin-1 file, a `.txt` file, a directory named `dir.md`, a 9 MiB file and a missing file are each refused with a dialog, and the app stays up. `README.MD` opens.
- A second launch hands its file to the running copy, and an empty window is reused. `mdview a.md a.md` opens one window, not two.
- A 30-column table scrolls sideways with whole words in its cells, and GTK logs nothing. With it showing, the view's minimum width is 629 px in a 900 px window, so the window isn't pinned.
- In a list item, wrapped lines, later paragraphs, code blocks and tables all line up with the item's text, and tables inside quotes and items are indented with them.

Not yet checked by hand: the Open dialog through the KDE portal, and dropping a file from Dolphin. Both need a person at the desktop.
