# mdview plan

Status, 2026-11-27: Phases 1 to 4 are built and checked, and installed for Kartik's user on `asus-vivobook`. [mdview.md](mdview.md) is the usage doc and records what was verified. `mdview` is a working name.

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
- Changed on disk: if the buffer is unmodified, mdview reloads it silently through a `gio::FileMonitor`. If the buffer is modified, a bar offers Reload or Keep Mine. A save never overwrites an outside change silently (see "Saving").

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

- **Dependencies:** exactly two direct crates. The first is `gtk4` 0.11.5 with feature `v4_12`, which covers `FileDialog`, `AlertDialog` and `UriLauncher` (all `v4_10`) and `CssProvider::load_from_string`; `load_from_data` is deprecated since 4.12 and would trip clippy. The host has GTK 4.24 and CI 4.22. The second is `pulldown-cmark` 0.13.6 with `default-features = false`, which drops only its HTML writer and `getopts`. gtk4 has no default features to trim, and its proc-macro crates aren't optional. No clap: `gtk::Application`'s `HANDLES_OPEN` takes the file arguments. No serde, no regex, no hashing crate (glib's `compute_checksum_for_data` gives SHA-256) and no async runtime: glib's main loop and gio's `_future` calls cover all I/O.
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

One binary crate, `mdview/`, in six modules (`find.rs` was split out of `window.rs` in Phase 2, and `link.rs` added in Phase 3).

| Module | Owns |
| --- | --- |
| `main.rs` | `gtk::Application` (`HANDLES_OPEN`), the app's actions and accelerators, the Quit sequence across windows, and loading `style.css` |
| `render.rs` | A pure function, no GTK, from Markdown to the rendered text, the styled character ranges and the anchored tables (Phase 2 adds a source line per block). It carries most of the unit tests. |
| `file.rs` | The pre-read checks, load and save through `gio::File`, the conflict check and the `FileMonitor` |
| `find.rs` | The find, replace and go-to-line bar's widgets, and the search, replace and go-to-line functions over a `TextView` |
| `window.rs` | The `ApplicationWindow`, header bar, filling the view's `TextBuffer` from `render.rs`'s output, the `Stack` of view and edit `TextView`s, wiring the find bar, the status line, the changed-on-disk bar and the dialogs |

App id `io.github.kartikakolia.mdview`: a bare `mdview` fails `Gio.Application.id_is_valid`. The desktop file is `data/io.github.kartikakolia.mdview.desktop`, because KDE on Wayland matches a window to its desktop entry by app id. Debug builds use the id with `.Devel` appended, so a `cargo run` doesn't hand its files over D-Bus to an installed copy that's running.

### Rendered view (`render.rs`)

The view is one read-only, wrapping `TextView` (`WrapMode::WordChar`, so long URLs break). The rendered text goes in plain, styled with tags:

- Headings get scaled bold, and emphasis, strong, strikethrough and inline code the obvious tags.
- Code blocks and front matter get monospace on a tinted paragraph background. Quotes get a left margin and a dimmed colour.
- List items get a hanging indent, and task items begin with ☐ or ☑.
- Links get an underline and a link colour, and the URL is kept for the click handler.

A GFM table goes in as a `Grid` anchored in the text (`create_child_anchor` and `add_child_at_anchor`), inside its own horizontal `ScrolledWindow`, so a table too wide even after its cells wrap scrolls instead of widening the window. Built, it turned out that `TextView` gives an anchored widget its minimum size, which for a scroller is near zero wide and for a wrapping grid is one character per column tall. So each table is sized on every width change: to its natural width, capped at the reading column, and to the height its cells wrap to at that width. A rule is a centred, dimmed line of dots, not an anchored `Separator`, which has no width of its own to take.

Tags need colour values, not CSS, so the colours still come from the theme through hidden probe widgets, and the tags take each one's `widget.color()`. As built there are three: a `LinkButton`, which carries the theme's own link colour (Nordic sets it with a `*:link` rule, `#5e81ac`, not a named colour), and two labels that `style.css` gives the dim and tint colours (`md-probe-dim`, `md-probe-tint`). Anchored widgets are styled by `style.css` directly.

One `TextView` per mode means one find bar and one zoom rule for both, and selection across blocks. It also keeps the scroll mapping simple: each block's start and source line are kept as offsets (`Rendered::blocks`), and switching modes looks up the block at the top of the view and scrolls the other view to its line through one reused mark (`scroll_to_mark`). The view is rebuilt only when entering view mode after the buffer has changed, tracked by a change counter, so typing never re-renders anything.

### Editor

A `TextView` in monospace with word-and-character wrap and the buffer's own undo stack (on by default, 200 levels). Find uses `TextIter::forward_search` and `backward_search` (with `CASE_INSENSITIVE` unless match case is on), and shows the current match by selecting it. As built, the match is also marked with a tag in the theme's selection colours (`theme_selected_bg_color` and `theme_selected_fg_color`, read through probe widgets): a `TextView` only draws its selection while it has focus, and during a search the focus is in the find field. Replace all runs between `begin_user_action` and `end_user_action`, so a single undo reverts it. The window's file `DropTarget` (`gdk::FileList`) runs in the capture phase, so a file dropped in edit mode opens instead of being pasted as a path by the `TextView`'s own drop handler.

### Saving (`file.rs`)

As built: every read of the document's file goes through `file::read_checked`, which checks it is still a regular file of at most 8 MiB, takes its etag, then reads it in capped chunks. mdview keeps only a hash of the bytes it last read or wrote. To save, it reads the file that way again and compares hashes, then calls `File::replace_contents_future` with the etag taken just before that read, and no backup. If either check shows an outside change, it asks: Overwrite, or Cancel (keep editing, then Save As). An Overwrite takes a fresh hash first, so a change made while the prompt was open asks again. Both checks are needed. The etag is only the mtime, and a probe that restored the old mtime after an outside edit slipped past it; the hash alone would leave a gap between the check and the write. The etag is taken fresh each time rather than kept from the load, so a `touch` that changed only the mtime isn't a conflict. Only one save runs at a time, so a second can't mistake the first for an outside change.

gio's save isn't always atomic. It writes a temporary file and renames it over the original only when the file is not a symlink or a hard link, its directory is writable, and the owner and permissions can be kept. Otherwise it truncates the file and rewrites it in place, as `gio/glocalfileoutputstream.c` says and probes of all three cases confirmed. So a save that fails on that path can leave the file damaged, and the error dialog says so and suggests Save As. The rename path also drops `user.*` extended attributes. Permissions survive either way.

## Failure handling

| Situation | What happens |
| --- | --- |
| Wrong extension, not a regular file, over 8 MiB, unreadable, not UTF-8, or contains NUL | Error dialog naming the file and the reason; the current document stays open |
| Save fails | Error dialog; the buffer stays marked modified. On the atomic path the file is untouched; on the in-place path the dialog warns it may be damaged and suggests Save As |
| File changed on disk, buffer unmodified | Reloaded silently |
| File changed on disk, buffer modified | Bar: Reload or Keep Mine. A later save hits the conflict check |
| File deleted while open | Save recreates it (confirmed by probe) |
| Save As to an existing `name.md` that the dialog never saw | Asks before overwriting |
| Quit with unsaved work in several windows | Prompts per window; any Cancel stops the quit |
| Theme changed while running | Restart needed (see Non-functional) |
| Crash, kill, SIGTERM or power cut with unsaved work | The next start reopens the work from its recovery copy (Phase 4) |
| A recovery copy can't be reopened | It moves to `recovery/failed/`, and one notice names the folder |
| Another mdview holds the recovery lock, the recovery folder is unsafe or not local, or a copy can't be moved, opened for writing or bumped at startup | This one runs with "Autosave off" in its status line, its reason in the tooltip |
| A recovery copy can't be written or deleted | "Autosave failed" in that window's status line, until a write succeeds |
| A document too large to copy | "Too large to autosave"; its last copy, with older text, is kept |

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
   - Exit: an edit-save round trip leaves the bytes identical except for the edit (`cmp`); an outside edit is caught, the mtime-restoring kind included; Quit with two modified windows prompts twice. All met on 2026-11-27, through the app's own actions over D-Bus with scripted prompt answers, since synthesised keystrokes don't reach Wayland windows; [mdview.md](mdview.md) has the evidence and what still needs a hand check.
   - Found while building it: the top line for the Ctrl+E mapping has to come from `TextView::line_at_y`, because the view's top-left corner is in the margin, where `iter_at_location` finds no text; and the dialogs' buttons have mnemonics (Alt+D for Discard and so on).
3. **Finish.** Zoom, F11, the status line, link handling, the desktop entry, install steps and the usage doc with its manual checklist.
   - Exit: the checklist passes, and mdview launches from the KDE menu and from Dolphin's "Open with". Built 2026-11-27; the automated part passed and launching through the desktop entry works, and the hand checklist in [mdview.md](mdview.md) is Kartik's to run.
   - As built: zoom is app-wide, a CSS font size above `style.css`'s priority, and the rendered view is rebuilt a frame after GTK applies it, since its measurements come from the font. Installing made mdview the effective default for `text/markdown`, as nothing was set explicitly; [mdview.md](mdview.md) says how to choose.
4. **Autosave and crash recovery.** Added at Kartik's request on 2026-11-27, after the foundations. Designed below ("Phase 4 design"); it is the one place mdview writes anywhere but the file being edited.

## Phase 4 design

Revision 9, 2026-11-27. Nine rounds of skeptic review (state correctness, platform and APIs, simplicity and UX) shaped it, most findings probed on this machine:

- **Round 1:** the first draft was unsound (non-atomic first writes, a two-file pair, resurrected copies, two primaries, `0644` files, a gated glib call, an unstable hash).
- **Round 2:** revision 2 was over-built, and had holes around in-flight writes, Save As and the meaning of "unsaved work".
- **Round 3:** deletes fenced only running writes, two writes shared a `.tmp`, the crash counter was async, and a startup comparison could hang.
- **Round 4:** only the timer checked for unsaved work, the deferred check could mark typing clean, and the startup `fsync`s were costly.
- **Round 5:** found no path that loses or resurrects text, but faulted revision 5's reworked same-file check, which reintroduced two windows on one file; that rework is reverted here. It also faulted an in-flight write undoing the crash counter's reset, a too-narrow mount denylist, a final `fsync` missed on the most common exit, and a quit that stopped silently after a save with typing during it.
- **Round 6:** all three lenses converged on one blocker. The mount check ran on the path string, so a local symlink into a FUSE mount passed it; and a recovered window's file watch, and `same_file`'s canonicalize when another file is opened, both touched the recovered path on the main thread before anything had checked it, so a dead mount could hang the launch. Smaller findings covered the re-ask after another path closed the window, the reset as one critical section, a failed delete, and several unstated fallbacks.
- **Round 7:** found no path that loses text, and prototyped the local-path walk under `strace` in a private mount namespace; it held for mount points, relative and chained symlinks, loops and overmounted ancestors. Its blocker was a mount point listed twice, where "last wins" can pick a mount hidden beneath another. Its other findings: `open_link` canonicalizing an unverified recovered path; a second window opened through a symlink at launch; autosave turning off partway through the scan; how a missing component counts; the order of the folder test and `mkdir`; `set_text` versus an undoable insert; Discard's reload installing a watch; and the re-ask's return value.
- **Round 8:** the platform lens found it ready, after re-running the prototype with the every-entry rule under `strace`. The others found two specification gaps. A link clicked in an unchecked recovered window could still canonicalize on the main thread. And the rule closing another window found to hold the same file was under-gated (mid-dialog, mid-load, or after a Save As); that rule is dropped. It also found that a copy whose bump fails could burn the others' counts.

- **Round 9:** all three lenses found it ready to implement, asking for small additions (a reload's pending file under the URI-only rule, the folder handed to the file dialogs, a typed load error for Discard, and wording), which are folded in below.

Revision 9 is the design that was implemented. The code then went through its own skeptic rounds, on the same three lenses, each with a `/code-review` pass. Their fixes changed five details of the design above, recorded here rather than rewritten into it:

- Autosave's gate leaves out the Discard marker: text the user chose to discard is still copied while it stays on screen (a quit cancelled at a later window leaves it open). The marker only stops the quit loop asking twice.
- Discard on the recovered bar has its own load, `discard_recovered`, not `load(file, ask = false)`. A Discard whose bar has since been hidden, by Keep or a save, does nothing. A reload that fails keeps the bar and says why. If the document was edited or saved after the click, or a save or its prompt is under way, it keeps everything and says "Not discarded"; otherwise a missing file closes the window. For a new document, Discard closes the window at once unless a save or prompt is under way, which gets the same "Not discarded".
- A recovered text is first tried in a spare text buffer; one the buffer can't hold exactly goes to `failed/`, counted in the failed-copies notice, and no window opens for it.
- `showing()` compares a pending load's file by URI only, in every window, since it may be a path nothing has checked. A file opened twice through different symlinks while the first is still loading gets two windows.
- A passing I/O error reading a copy at startup leaves every copy for a later start with autosave off, rather than treating that copy as failed; and the newest copy of a file is chosen among all decoded copies, so an older one never reopens in place of a newer one that failed.

**Goal.** A crash, a `kill`, a SIGTERM or a power cut loses at most about 5 seconds of unsaved typing, as far as the filesystem honours `fsync`. **Not a goal:** writing to the document's own file without being asked. Saving stays explicit.

**Where.** `$XDG_STATE_HOME/mdview/recovery/` (or `~/.local/state/…` when the variable is unset or relative), computed by hand, with `recovery-devel/` for a debug build. Folders, `failed/` included, are created `0700` with `std::fs::DirBuilder`. At startup `recovery/` must pass the local-path test (below), must not be a symlink, and its owner must be the current user (`gio::Credentials::new().unix_user()`); a wider mode is tightened to `0700`. If any of that fails, autosave is off for the session. With autosave off, this instance neither writes nor deletes copies.

**The recovery lock.** In `startup` the app takes an exclusive `flock` on `recovery/lock` (`std::fs::File::try_lock`, Rust 1.89) and keeps the `File` in a `static LOCK: OnceLock<File>` for the life of the process. Only the holder writes or recovers copies. Another primary runs with autosave off.

**What.** One file per window with unsaved work, `recovery/<window-uuid>.md`. Its header line is `mdview-recovery 1 <attempts> <time> <length> <uri> <guard>`, and the text follows byte for byte.

- `attempts` is a single digit at a fixed offset (byte 18), so it can be changed in place.
- `time` is the Unix time of the write.
- `length` is the text's exact byte count.
- `uri` is the document's URI, normalised by `gio::File::for_uri(…).uri()` (percent-encoded, no filesystem access), or `-` for a new document.
- `guard` is the SHA-256 of the file as last read or written, or `-`.

The text may be up to `file::MAX_BYTES` (8 MiB) and the header up to 16 KiB, enough for any local path, since a `PATH_MAX` path percent-encodes to about 12 KiB. A copy over either limit isn't written, and "Too large to autosave" shows. `file::Guard` moves to SHA-256 (`glib::compute_checksum_for_data`).

**Unsaved work** means `has_doc`, the modified flag, and the window's close not yet agreed.

**Same file.** Unchanged from Phase 3 for ordinary windows: `same_file` canonicalizes both paths on the main thread (see Not covered). A recovered window is the exception until its path has passed the local-path test. Until then, `showing()` matches it by normalised URI only and never canonicalizes its path. The rule covers the window's pending load too: a Discard reload of an unchecked path that never returns leaves it pending, and `showing()` still matches it by URI only. The URI-only state ends when the path passes the deferred check, or when a load or Save As in that window succeeds, since the file has then just been read or written. While a window is unchecked, Open and Save As don't hand its folder to the file dialog as the starting folder. The same rule holds for `open_link` in such a window: its same-document check, and the `showing()` check for a link it follows (a relative link resolves into the recovered file's unchecked folder), both match by normalised URI only. The link's file itself is then read by gio's asynchronous load, off the main thread. Recovery's own duplicate check compares normalised URIs only, and touches nothing.

Because recovered windows open before file arguments and before any check finishes, `mdview /symlink/to/X` with X recovered opens a second window on X. Both stay, and each save's guard keeps either from silently overwriting the other. Nothing later closes or merges them.

**The local-path test.** This decides whether a path can be touched without risk of an uninterruptible wait. It runs on `gio::File::path()`, which gio has already normalised (`..` collapsed), the same string `watch` and `canonicalize` use. A file with no local path (`path()` is `None`) isn't local. It walks the path one component at a time from `/`. Before touching each prefix, it finds that prefix's mount by the longest path-component prefix in `/proc/self/mountinfo` (with `\040`-style escapes decoded). The type is read after mountinfo's ` - ` separator. If the filesystem type isn't on the allowlist, the path isn't local, and nothing inside that mount is touched, the mount point included. A mount point listed more than once (an overmount, or a mount placed beneath another) is local only if every entry for it is allowlisted, since the later line isn't always the visible mount. Otherwise it `lstat`s the prefix. `ENOENT` counts as local, because the missing component's parent was local; this is how "The file no longer exists" is reached. Any other `lstat` error counts as not local. A symlink is followed with `readlink`, which reads the local directory it sits in, and the walk continues through the target, stopping as not local after 40 links.

- The allowlist: ext4, ext3, ext2, btrfs, xfs, f2fs, bcachefs, zfs, tmpfs, vfat, exfat and ntfs3. Anything else (FUSE, NFS, CIFS, autofs, overlay, 9p and the rest) isn't local.
- A FUSE request the daemon has read waits uninterruptibly, so touching a dead one could keep the process from exiting.
- The test runs off the main thread, except for `recovery/` itself at startup. That check runs once, before `DirBuilder` creates anything, so a `~/.local/state` symlink into a dead mount can't hang the `mkdir`. The symlink, owner and mode checks on `recovery/` come after `DirBuilder`, since on a first run there is nothing to check before it.
- `/proc/self/mountinfo` is a snapshot: a mount that appears between the test and the touch isn't caught.

**The slot.** Each window shares an `Arc<Mutex<Slot>>` with the thread pool, holding a generation, a write sequence number, a `closed` flag and the window's current `attempts`. The slot mutex is locked with `lock().unwrap_or_else(PoisonError::into_inner)`, and the main thread never holds it across an `.await`.

- **The write gate** is used by the timer, the post-save call and the follow-up. On the main thread, it does nothing unless there is unsaved work. If a write is in flight, it marks one wanted. Otherwise, under the slot mutex, it does nothing if `closed` is set; if not, it records the generation, takes the next sequence number `n`, and snapshots the text, URI and guard.
- **The blocking write**, on `gio::spawn_blocking`, writes `<uuid>.<n>.tmp`, created with `create_new` at mode `0600`, and calls `sync_all`. Under the slot mutex it does two things. First, if the generation is unchanged and `closed` is unset, it writes the slot's current `attempts` digit into the `.tmp` at byte 18 (`write_at`, never `append`) and renames the `.tmp` over `<uuid>.md`. Otherwise it removes the `.tmp`, ignoring `ENOENT`. The stamped digit isn't `fsync`ed again, so after a power cut a copy can show its pre-reset digit and fail one crash early; no text is lost. With the slot mutex released, it `sync_all`s the folder. Every write has its own `.tmp`, and the digit stamped last is always the current one, so a write that started before a reset can't undo it.
- **A delete** runs on the main thread. Under the slot mutex it raises the generation and removes `<uuid>.md`; the folder `fsync` follows on the pool. A removal that fails with anything but `ENOENT` shows "Autosave failed", since the copy would otherwise come back at the next start. `recovery/` is local (checked at startup), so the unlink can't stall the main thread. A **final delete** also sets `closed`, so no write can start or land afterwards.
- **When a write's handle resolves**, and only then, the in-flight flag clears. A panic counts as a failure in a debug build; a release build aborts on panic (`Cargo.toml`), so it ends the app and the last written copy, if any, reopens at the next start. A failed write re-arms the 5-second timer, so the copy catches up once the cause clears. If a write was wanted, the gate runs again at once; edits alone wait for the timer. A write outstanding for over 30 seconds shows "Autosave failed".

**When.** An edit arms a 5-second one-shot timer unless one is armed. There are no timer handles: a late fire after a close is harmless, because the gate and `closed` refuse it. After `save` and after `choose_and_save`, once the file and the guard are both updated (after `finish_save`, and for Save As after `file.replace`), the gate is called, and it writes only if edits came in during the save. A document that grows past the limits keeps its last copy, which holds older text, and "Too large to autosave" shows.

**Deleting** follows two rules:

1. The modified flag goes false: a save with no edits during it, `show` replacing the text, or an undo back to the saved text.
2. A **final** delete whenever a window closes, by any path, including the existing fast path for a window with nothing unsaved; and for every window just before `app.quit()`. GApplication's `shutdown`, which runs after the main loop ends, including after the last window closes, then `fsync`s the folder synchronously. It doesn't run on SIGTERM, on an abort, or when GTK exits because the compositor connection dropped. Copies then remain (the intent), and a delete whose folder `fsync` hadn't run can come back after a power cut, where the bar's Discard deals with it.

A clean quit leaves only `lock`.

**Prompts.** `confirm_discard`'s Save now re-asks if the save succeeded but the document is still modified (typing during the save), instead of closing or quitting with the copy that holds that typing deleted. It re-asks only while the window has unsaved work. If another path has agreed the window's close meanwhile, it returns true without presenting the window, so a quit carries on. It returns true only when the document is saved or discarded, and false on Cancel or a failed save. The quit loop then simply asks the next window that has unsaved work.

**Crash counter.** `attempts` counts starts that recovered a copy without its window then staying up for 10 seconds.

- In `startup`, before any window exists, a copy whose digit reads 2 or more moves to `failed/`.
- Any other copy has its digit raised by one in place: one `write_at` with no `fsync`, leaving `time` unchanged. A process crash keeps the page cache, and a power cut only loses one count. So a copy fails after two starts that recovered it and then crashed.
- The recovered window holds the raised value in its slot, so its own writes carry it.
- After 10 seconds up, the window, in one critical section under the slot mutex and unless `closed` is set, sets the slot's `attempts` to 0 and writes 0 into `<uuid>.md` if that file exists, opened by path and never created.
- The moves to `failed/` happen first. Then every remaining copy is opened for writing, and only once all have opened is any digit bumped. If a move fails, or any copy can't be opened for writing (any error: `EROFS`, `EACCES`, `EMFILE` and so on), autosave is off, nothing is bumped, and no copy opens on this start. The copies are left as they are for a later one (those already moved to `failed/` stay there), and the "Autosave off" tooltip says how many. A bump that fails after others succeeded leaves those others one count higher; no text is lost. A Discard bar exists only when autosave is on, so its Discard always deletes.

**Recovery**, in `startup` and only when the lock is taken, in this order: sweep, decode, filter, then bump the copies that remain.

- Stray `*.tmp` files are swept. Names that aren't a uuid with `.md` are ignored.
- Each uuid-named `.md` is read synchronously after a `symlink_metadata` check: it must be a regular file, not a symlink, within the limits. A FIFO swapped in by the same user between the check and the open is accepted as a risk.
- It is then decoded, with `length` required to match exactly.
- Copies that fail, read 2 or more attempts, or are older than another copy with the same normalised URI (newest by `time`; on a tie, the byte-wise greater lowercase uuid string wins) move to `failed/`.
- Nothing reads the documents' own files during `startup`.

The recovered windows open at the first `activate` or `open` (a launch with files gets only `open`), before any file arguments, so `showing()` finds a recovered document rather than opening it twice. They open directly, one window each, through a path that never sets the modified flag false:

- in edit mode
- with the recovered text, put in by `set_text` (which can't be undone, so the buffer stays modified), marked modified
- with the copy's uuid, URI and guard, and the raised attempts
- not yet watching its file: `watch` (whose `inotify_add_watch` walks the path on the main thread) waits until the deferred check has found the path local

A recovered window shows a bar with **Keep** and **Discard**, styled like the changed-on-disk bar. The two can show at once, one above the other, so "Keep" and "Keep Mine" may appear together.

- **For a file:** "Recovered unsaved changes to “name” (autosaved 27 Nov, 18:02). Keep them, or discard them and reload the file."
- **For a new document:** "Recovered an unsaved new document (autosaved …). Keep it, or discard it and close this window."
- **Times** use `glib::DateTime::from_unix_local`, formatted `%H:%M` today, `%-d %b, %H:%M` this year, and `%-d %b %Y, %H:%M` otherwise.
- **Keep** hides the bar. Nothing else changes.
- **Discard** for a file reloads it without a second prompt (built as `discard_recovered`; see the five details above), so the modified flag goes false and rule 1 deletes the copy. `file::load` gains a typed error so this can be told apart: if the file no longer exists (`NOT_FOUND`), or for a new document, Discard closes the window, with its close marked agreed first so there is no second prompt. Any other load error keeps the bar and the copy, and shows the error.

**The deferred check.** After the windows open, each recovered file is checked off the main thread on `spawn_blocking`. It first runs the local-path test. A path that isn't local is left alone: the window keeps no file watch and URI-only matching, and gets no "changed on disk" note. A local path gets the rest of the check, and then, if the window's file is still the one snapshotted and it isn't already watched, the window starts watching it and matches it through `same_file` like any other. A Discard that reloads the file goes through `show`, which watches it: that is an ordinary window from then on, its path having just been read successfully.

- The check snapshots the window's edit count, its save count and its file, then reads `metadata().is_file()`, the length and the bytes.
- **Disk equals the recovered text:** the copy is redundant. If the edit count, the save count and the file are all unchanged, the window becomes an ordinary clean one: its guard is set from the disk bytes, the modified flag goes false (rule 1 deletes the copy), and the bar goes. If the user has typed since, only the guard is set from the disk bytes (unless a save or a load has set it meanwhile), so a save doesn't report a change nobody made.
- **Disk matches the copy's guard:** nothing to add.
- **Disk differs from both, or is missing:** if the bar is still showing and no save has happened since the snapshot, it gains "It has changed on disk since; saving will ask before overwriting." or "The file no longer exists; saving recreates it."
- A check that never returns leaves the bar as it was. A note that arrives after Keep has hidden the bar is dropped; a save's guard still catches the change.

**Failed copies.** If any copies moved to `failed/` on this start, one `AlertDialog` (via `choose_future`) shows over the first window, never parentless:

- Message: "Some recovered text couldn't be reopened".
- Detail: "mdview kept 1 copy (or N copies) in `<failed folder>`. Each is the text after one header line. Delete them when you no longer need them." The folder is the real `recovery/failed/` (or `recovery-devel/failed/`), with `~` for home as the status line shows it.
- Buttons: Open Folder (`gtk::FileLauncher`) and Close.

**Status line.** "Autosave off" shows in every window, with its reason in the tooltip: the lock is held elsewhere; the folder is unsafe or not local; or a copy couldn't be moved, opened for writing or bumped at startup, in which case the tooltip also gives how many were left for a later start. "Autosave failed" (until a write succeeds) and "Too large to autosave" show in the affected window. Each joins the existing " · " list, with its reason as a tooltip.

**Logout.** Plasma 6 first asks every window to close (`xdg_toplevel.close`), so mdview's prompts appear. After 10 seconds Plasma offers to log out anyway. The process then ends either by SIGTERM, which GApplication doesn't handle, or when KWin goes away first and GTK exits on the lost compositor connection. Either way its copies remain unless that window's close was agreed. This comes from KWin's source and bug tracker and hasn't been observed here; a real logout is on the manual checklist.

**Not covered.**

- A copy is plain text in the home folder, so a document on an encrypted mount has an unencrypted copy until it is saved or discarded.
- A power cut is covered only as far as the filesystem keeps `fsync`'s promise.
- A recovered file whose path isn't local (by the local-path test, symlinks followed) gets no file watch, until a Discard reloads it, and no "changed on disk since" note, though a save still guards it.
- A mount point listed more than once counts as not local, so an automounted filesystem (`autofs` beneath the real one) is never local. An `overlay` (toolbox, distrobox) or an `ecryptfs` home isn't either, being off the allowlist. If `recovery/` is on one, autosave is off.
- gio's inotify backend rescans missing paths on its own thread under the lock `watch` also takes, so a mount appearing later could still stall a later `watch`; ordinary windows share that exposure.
- The existing `same_file` canonicalizes on the main thread, and so can stall on a dead network mount for windows the user opened; Phase 4 never applies it to a recovered path that hasn't passed the local-path test.
- The pre-existing Save As race (another window opening the target during the save) can still bind two windows to one file. Recovery then keeps the newer copy and puts the older in `failed/`.
- The usage doc says where copies live, and that deleting the folder while mdview isn't running clears them.

**Shape.** A new `recovery.rs`, holding:

- the paths, folder checks and recovery lock
- the header encode and decode (pure, unit-tested)
- the slot, the blocking write, the delete, and the in-place digit write
- the local-path test (mountinfo parsing and the prefix lookup pure and unit-tested)
- the startup scan

`window.rs` gains the write state, the gate, the two delete rules, the post-save calls, the reworked Save answer in `confirm_discard`, the recovered windows and bar, and the deferred check. `main.rs` gains the `startup` scan, the `shutdown` folder `fsync`, and the recovery step in `activate` and `open`. No new crate; `rust-version` rises from 1.88 to 1.89.

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
