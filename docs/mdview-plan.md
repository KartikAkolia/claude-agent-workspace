# mdview plan

Status, 2026-11-27: Phase 1, the viewer, is built and checked; Phases 2 and 3 and autosave are not started. [mdview.md](mdview.md) is the usage doc and records what was verified. `mdview` is a working name.

mdview is a small native Markdown viewer and editor for Kartik's CachyOS laptop (`asus-vivobook`, KDE Plasma on Wayland). It opens on the rendered document, Ctrl+E flips the same window to the source, and it does the basic jobs of an ordinary text editor for Markdown files and nothing else. It draws with plain GTK4, so it takes on the system GTK theme (Nordic, Papirus-Dark, Noto Sans) and carries no colours of its own.

## Decisions taken

Kartik chose these on 2026-11-27:

1. **Front end: a GTK4 window through gtk4-rs, without libadwaita.** libadwaita ships its own stylesheet and ignores `gtk-theme-name`, so it would not follow Nordic. Plain GTK4 does: a GTK 4.24.2 probe on this session reported `gtk-theme-name = Nordic`, `gtk-icon-theme-name = Papirus-Dark`, `gtk-font-name = Noto Sans 10` and dark preferred, and the header bar is drawn by GTK and styled by Nordic. The ratatui option, which would have reused minecraft-tui, was turned down: it could copy GTK's colours, but not its fonts, heading sizes or images.
2. **"Strict Markdown" means CommonMark plus three GFM extensions:** tables, task lists and strikethrough. Of the 106 Markdown files this repo tracks outside the reference clones, 32 use tables, 5 task lists and 3 strikethrough.
3. **Layout: view first, Ctrl+E to edit.** One pane, either the rendered view or the source, never both.
4. **Location: a new tracked top-level folder, `mdview/`,** linted like `minecraft-tui/`, with its own CI workflow.

## Requirements

### Functional

File handling:

- Open with Ctrl+O, from command-line arguments, by dropping a file on the window, or from the desktop entry (`MimeType=text/markdown`). Each file opens in its own window; opening a file that is already open focuses that window instead.
- New (Ctrl+N), Save (Ctrl+S), Save As (Ctrl+Shift+S), Close window (Ctrl+W) and Quit (Ctrl+Q).
- Unsaved work prompts Save, Discard or Cancel before a close or a quit, and before a link click or a drop replaces the document. Quit asks each window with unsaved work in turn, and quits only if none cancels. GTK's own `quit` skips `close-request` entirely, which a probe confirmed, so the app's Quit can't simply call it.
- Replacing the document always goes: load and validate the new file, then prompt, then swap. A file that fails to load never costs the current one.
- Changed on disk: if the buffer is unmodified, mdview reloads it silently through a `gio::FileMonitor`. If the buffer is modified, a bar offers Reload or Keep mine. A save never overwrites an outside change silently (see "Saving").

Editing, in source mode:

- Undo and redo, cut, copy, paste and select all, plus the right-click menu. These are all built into `TextView`, which already binds Ctrl+Z, Ctrl+Shift+Z and Ctrl+Y, so the app registers no accelerators of its own for them. A load isn't undoable, because `set_text` isn't.
- Replace and Replace all (Ctrl+H), with Replace all as one undo step. Go to line (Ctrl+L).
- Word wrap is on by default and toggled from the menu. Tab inserts four spaces.

In both modes:

- Find (Ctrl+F) with next and previous (Enter, Shift+Enter, F3, Shift+F3) and a match-case toggle. In view mode it searches the rendered text.
- Ctrl+E toggles view and edit and keeps roughly the same place in the document. Zoom in, out and reset (Ctrl+=, Ctrl+-, Ctrl+0) and F11 for fullscreen.
- A status line shows the file's directory, whether it is modified, the line and column (in edit mode) and a word count.
- Links: mdview handles every click itself and never falls through to a default launcher. It strips any `#fragment`, percent-decodes the path with `glib::Uri`, and resolves it against the file's directory. A relative `.md` link opens in the same window. `http`, `https` and `mailto` open through `gtk::UriLauncher`, which goes via the desktop portal. Every other scheme, and every relative link in an unsaved New document, does nothing.
- Images show as their alt text in italics. mdview never loads image files or touches the network. None of the 106 tracked docs contains an image.

Strictness:

- Only `.md` and `.markdown` files open, matched without regard to case, so `README.MD` opens (shared-mime-info's `*.md` glob already offers it). Anything else is refused with an error dialog.
- Before reading anything, mdview checks that the path, following symlinks, is a regular file of at most 8 MiB. A FIFO named `x.md` hung `load_contents` in a probe, and a symlink to `/dev/zero` killed the process outright.
- The file must be valid UTF-8 with no NUL byte. NUL is valid UTF-8, but `TextBuffer::set_text` rejects it: in a probe the buffer came back empty, so a save would have wiped the file. After loading, mdview also checks that the buffer holds exactly the bytes read.
- Save As adds `.md` when the name has no extension and refuses any other extension. Because the file dialog only checked the name as typed, mdview asks before overwriting an existing file at the final name.
- What is saved is the buffer's text byte for byte. A probe round-tripped CRLF, lone CR, mixed endings, a BOM, U+2028 and U+2029 and a missing final newline unchanged. Lines the user types end in `\n`.
- Parser options: `ENABLE_TABLES | ENABLE_TASKLISTS | ENABLE_STRIKETHROUGH | ENABLE_YAML_STYLE_METADATA_BLOCKS`. Without the last one, a `---` front-matter block parses as a rule and a heading; 21 tracked files start with one, all the `SKILL.md` files among them. Front matter shows as a dimmed monospace block, not as data. `ENABLE_GFM` stays off, since it only adds `[!NOTE]` alerts. Off as well: math, heading attributes, smart punctuation, wikilinks and bare-URL autolinks, which all stay literal.
- What else shows literally: raw HTML blocks, inline HTML (escaped, inside its paragraph) and HTML comments (dimmed), including the markdownlint comments in 5 tracked files. A UTF-8 BOM is skipped for parsing only. Footnotes aren't supported: CommonMark reads a `[^1]: note` line as a link definition, so `[^1]` renders as a link.

### Non-functional

- **Dependencies:** exactly two direct crates. The first is `gtk4` 0.11.5 with feature `v4_12`, which covers `FileDialog`, `AlertDialog` and `UriLauncher` (all `v4_10`) and `CssProvider::load_from_string`; `load_from_data` is deprecated since 4.12 and would trip clippy. The host has GTK 4.24 and CI 4.22. The second is `pulldown-cmark` 0.13.6 with `default-features = false`, which drops only its HTML writer and `getopts`. gtk4 has no default features to trim, and its proc-macro crates aren't optional. No clap: `gtk::Application`'s `HANDLES_OPEN` takes the file arguments. No serde, no regex, no hashing crate (std's `DefaultHasher` is enough) and no async runtime: glib's main loop and gio's `_future` calls cover all I/O.
- **Build time:** measured on this 16-thread laptop with Rust 1.100.0, using a 48-line probe app built on Application, Stack, TextView and pulldown-cmark (62 crates compiled):

  | Build | Time |
  | --- | --- |
  | Cold dev | 29.1 s |
  | Cold release | 35.9 s |
  | Cold clippy | 23.6 s |
  | Incremental dev, after a real edit | 0.18 s |
  | CI-like: 4 cores, not incremental, cold clippy plus tests | 51.1 s |

  Most of it is a serial chain: glib, then gio, then pango, gdk4 and gsk4, then gtk4. The proc macros add only about 3 s, mold isn't installed, and `ld.lld` is already the linker. `[profile.dev]` is copied from minecraft-tui (line tables only, no debug info for dependencies). The targets are under 40 s cold and under 1 s incremental, and a third crate needs a measured reason.
- **Theming:** no colour literals anywhere. An embedded `style.css` uses only Nordic's named colours, with `alpha()` of them: as built, `@theme_fg_color`, `@insensitive_fg_color` and `@borders`. Sizes are in `em`, relative to the GTK font, and code uses `font-family: monospace`. In GTK 4.24 those all resolve with no warning, but a misspelt name fails silently, so `style.css` lists the names it uses in a comment and the manual check covers each one. Named colours are going away in GTK5, which is when this CSS would need custom properties instead.
- **CSS priority:** `style.css` loads at `STYLE_PROVIDER_PRIORITY_USER + 1`. KDE's `~/.config/gtk-4.0/gtk.css` imports the whole Nordic sheet at USER priority (800), and GTK compares priority before specificity. In a probe, a TextView rule at APPLICATION priority (600) lost to Nordic's `.view` colour, and at 801 it won. Every class is prefixed `md-`, because Nordic defines `.h1` to `.h4` with sizes in px.
- **Theme and font changes need a restart.** GTK4 reads the user `gtk.css` once, at startup (GNOME/gtk#3409, still open), and on this host that file imports Nordic directly. A probe that switched themes at runtime kept Nordic's colours.
- **Responsiveness:** this repo's largest docs, `docs/archival.md` (161 KB) and `docs/handoff.md` (159 KB), open and render without a visible stall. Phase 1 measures how far beyond that it holds; the 8 MiB read cap is the hard limit.

### Out of scope

Tabs, file trees and sidebars, a live side-by-side preview, image display, recent files (the KDE file dialog already lists them), export to HTML or PDF, printing, spell check, syntax highlighting through GtkSourceView (`gtksourceview5` isn't installed, and it would add a crate and a system package), list continuation on Enter, vim keys, plugins, a settings window and remote content of any kind.

Autosave and crash recovery come after Phase 3 (Kartik, 2026-11-27: "This can be added", once the foundations work). Until then, a crash or a forced logout loses unsaved work, since GTK's logout inhibit "is not guaranteed to work on all platforms".

## Shape

One binary crate, `mdview/`, in four modules.

| Module | Owns |
| --- | --- |
| `main.rs` | `gtk::Application` (`HANDLES_OPEN`), the app's actions and accelerators, the Quit sequence across windows, and loading `style.css` |
| `render.rs` | A pure function, no GTK, from Markdown to the rendered text, the styled character ranges and the anchored tables (Phase 2 adds a source line per block). It carries most of the unit tests. |
| `file.rs` | The pre-read checks, load and save through `gio::File`, the conflict check and the `FileMonitor` |
| `window.rs` | The `ApplicationWindow`, header bar, filling the view's `TextBuffer` from `render.rs`'s output, the `Stack` of view and edit `TextView`s, the shared find, replace and go-to-line bar, the status line, the changed-on-disk bar and the dialogs |

App id `io.github.kartikakolia.mdview`: a bare `mdview` fails `Gio.Application.id_is_valid`. The desktop file is `data/io.github.kartikakolia.mdview.desktop`, because KDE on Wayland matches a window to its desktop entry by app id. Debug builds use the id with `.Devel` appended, so a `cargo run` doesn't hand its files over D-Bus to an installed copy that's running.

### Rendered view (`render.rs`)

The view is one read-only, wrapping `TextView` (`WrapMode::WordChar`, so long URLs break). The rendered text goes in plain, styled with tags:

- Headings get scaled bold, and emphasis, strong, strikethrough and inline code the obvious tags.
- Code blocks and front matter get monospace on a tinted paragraph background. Quotes get a left margin and a dimmed colour.
- List items get a hanging indent, and task items begin with ☐ or ☑.
- Links get an underline and a link colour, and the URL is kept for the click handler.

A GFM table goes in as a `Grid` anchored in the text (`create_child_anchor` and `add_child_at_anchor`), inside its own horizontal `ScrolledWindow`, so a table too wide even after its cells wrap scrolls instead of widening the window. Built, it turned out that `TextView` gives an anchored widget its minimum size, which for a scroller is near zero wide and for a wrapping grid is one character per column tall. So each table is sized on every width change: to its natural width, capped at the reading column, and to the height its cells wrap to at that width. A rule is a centred, dimmed line of dots, not an anchored `Separator`, which has no width of its own to take.

Tags need colour values, not CSS, so the colours still come from the theme through hidden probe widgets, and the tags take each one's `widget.color()`. As built there are three: a `LinkButton`, which carries the theme's own link colour (Nordic sets it with a `*:link` rule, `#5e81ac`, not a named colour), and two labels that `style.css` gives the dim and tint colours (`md-probe-dim`, `md-probe-tint`). Anchored widgets are styled by `style.css` directly.

One `TextView` per mode means one find bar and one zoom rule for both, and selection across blocks. It also keeps the scroll mapping simple: each block's source line becomes a mark, and switching modes looks up the block at the top of the view and scrolls the other view to its line (`scroll_to_mark`). The view is rebuilt only when entering view mode after the buffer has changed, tracked by a change counter, so typing never re-renders anything.

### Editor

A `TextView` in monospace with word-and-character wrap and the buffer's own undo stack (on by default, 200 levels). Find uses `TextIter::forward_search` and `backward_search` (with `CASE_INSENSITIVE` unless match case is on), and shows the current match by selecting it, so the highlight is the theme's own selection colour. Replace all runs between `begin_user_action` and `end_user_action`, so a single undo reverts it. The window's file `DropTarget` (`gdk::FileList`) runs in the capture phase, so a file dropped in edit mode opens instead of being pasted as a path by the `TextView`'s own drop handler.

### Saving (`file.rs`)

Loading uses `File::load_contents_future`, which returns the bytes and the file's etag. mdview also keeps a hash of the bytes it loaded. To save, it re-reads the file and compares hashes, then calls `File::replace_contents_future` with the etag and no backup. If either check shows an outside change, it asks: Overwrite, or Cancel (keep editing, then Save As). Both checks are needed. The etag is only the mtime, and a probe that restored the old mtime after an outside edit slipped past it; the hash alone would leave a gap between the check and the write. After a successful save, the new etag and hash replace the old ones.

gio's save isn't always atomic. It writes a temporary file and renames it over the original only when the file is not a symlink or a hard link, its directory is writable, and the owner and permissions can be kept. Otherwise it truncates the file and rewrites it in place, as `gio/glocalfileoutputstream.c` says and probes of all three cases confirmed. So a save that fails on that path can leave the file damaged, and the error dialog says so and suggests Save As. The rename path also drops `user.*` extended attributes. Permissions survive either way.

## Failure handling

| Situation | What happens |
| --- | --- |
| Wrong extension, not a regular file, over 8 MiB, unreadable, not UTF-8, or contains NUL | Error dialog naming the file and the reason; the current document stays open |
| Save fails | Error dialog; the buffer stays marked modified. On the atomic path the file is untouched; on the in-place path the dialog warns it may be damaged and suggests Save As |
| File changed on disk, buffer unmodified | Reloaded silently |
| File changed on disk, buffer modified | Bar: Reload or Keep mine. A later save hits the conflict check |
| File deleted while open | Save recreates it (confirmed by probe) |
| Save As to an existing `name.md` that the dialog never saw | Asks before overwriting |
| Quit with unsaved work in several windows | Prompts per window; any Cancel stops the quit |
| Theme changed while running | Restart needed (see Non-functional) |

## Repo integration

- `mdview/` gets `Cargo.toml` (edition 2024, `rust-version` pinned, `[profile.*]` sections copied from `minecraft-tui/Cargo.toml` with their comments), `src/`, `style.css`, the desktop file under `data/` and a committed `Cargo.lock`.
- Its usage doc, `mdview.md` in `docs/`, covers usage, keys, build, install and the manual checklist, the way `docs/minecraft-tui.md` does. It gets a Repository Map row in `AGENTS.md`, replacing this plan's.
- `.githooks/pre-commit`: the `rust_staged` block, which today checks only `minecraft-tui/`, becomes a loop over both crates, running `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings` in each one that has staged changes.
- `.github/workflows/mdview.yml` is a slim, single job, not a copy of the 245-line `minecraft-tui.yml`: install `libgtk-4-dev`, then fmt, clippy and the tests, with the same pinned toolchain and rust-cache. It has no release artifact and no timing harness. It runs on `ubuntu-latest`, which moved to Ubuntu 26.04 (GTK 4.22) in October and November 2026 (actions/runner-images#14748). `docs/repo-tooling.md` gets a note. A shared `workflow_call` workflow waits until a third crate exists.
- Installing needs no root: `cargo build --release`, then `install -Dm755` into `~/.local/bin` and the desktop file into `~/.local/share/applications`. Making mdview the default for `text/markdown` (`xdg-mime default`) is left to Kartik.

## Phases

Three PRs for the foundations, then autosave. Each ends with fmt, clippy and the tests passing, a `/code-review` pass with its findings fixed (AGENTS.md non-negotiable 7), and a manual check on this laptop.

1. **Viewer. Done 2026-11-27.** Scaffold, profiles, CI and the hook change; the app id and single-instance handling; `render.rs` with unit tests; the view `TextView` and `style.css`; and Open, drop and the strict pre-read checks.
   - The tests cover each block type, the three GFM extensions, front matter, raw and inline HTML staying literal, the BOM skip, and tables' anchors and markup escaping. Source-line numbers moved to Phase 2, where the Ctrl+E scroll mapping is their only user.
   - Exit: the window visibly uses Nordic, and every `style.css` colour resolves; `AGENTS.md`, `docs/archival.md` and a table-heavy doc render correctly with no stall; a FIFO, a `/dev/zero` symlink, a NUL file and a non-UTF-8 file are each refused; cold and incremental build times are recorded. All met; [mdview.md](mdview.md) has the evidence.
2. **Editor.** The Ctrl+E toggle with the scroll mapping and the source-line numbers it needs; New, Save and Save As; the unsaved-work prompts, including the Quit sequence and the load-then-prompt-then-swap order; the conflict check and the `FileMonitor`; and find, replace and go to line.
   - Exit: an edit-save round trip leaves the bytes identical except for the edit (`cmp`); an outside edit is caught, the mtime-restoring kind included; Quit with two modified windows prompts twice.
3. **Finish.** Zoom, F11, the status line, link handling, the desktop entry, install steps and the usage doc with its manual checklist.
   - Exit: the checklist passes, and mdview launches from the KDE menu and from Dolphin's "Open with".
4. **Autosave and crash recovery.** Added at Kartik's request on 2026-11-27, after the foundations. To be designed then; it is the one place mdview would write anywhere but the file being edited.

## Trade-offs

A cold build costs about 29 s, against 5 s for the TUI option. Each of those crates is a thin binding to a library already on the system, though, and an edit rebuilds in under a second.

Without libadwaita there are no adaptive layouts or toasts, which this app doesn't need.

Rendering into a `TextView` gives find in view mode and selection across blocks. It costs the indirection of probe widgets for tag colours, and about 40 lines of click and hover handling for links.

Without GtkSourceView, the source has no syntax highlighting.

Any of these would reopen the design:

- Documents well past the measured limit: render lazily.
- Wanting source highlighting: gtksourceview5 plus the `sourceview5` crate, at a measured build cost.
- Wanting images: a `Texture::from_file` behind the same pre-read checks, with `ContentFit::ScaleDown` so small images aren't enlarged.
- A move to GTK5: named colours become custom properties.
