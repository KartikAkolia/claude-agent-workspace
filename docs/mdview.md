# mdview

mdview is a small GTK4 Markdown viewer and editor, written in Rust, that takes on the system GTK theme (Nordic, Papirus-Dark and Noto Sans on `asus-vivobook`). It lives in `mdview/`. The design, the decisions behind it and the pitfalls the skeptic reviews found are in [mdview-plan.md](mdview-plan.md); read that before changing it.

Status, 2026-11-27: Phases 1 to 4 (the viewer, the editor; links, zoom, the status line and the desktop entry; autosave and crash recovery) are built and checked on `asus-vivobook`, and installed there for Kartik's user (the release build of commit `58d065f`, reinstalled on 2026-11-27).

## Install

No root needed. From `mdview/`:

```bash
cargo build --release
install -Dm755 target/release/mdview ~/.local/bin/mdview
install -Dm644 data/io.github.kartikakolia.mdview.desktop ~/.local/share/applications/io.github.kartikakolia.mdview.desktop
update-desktop-database ~/.local/share/applications
kbuildsycoca6   # KDE's menu and "Open with" pick it up straight away
```

mdview then appears in the KDE menu and in Dolphin's "Open with" for Markdown files. With no default chosen for `text/markdown` in `~/.config/mimeapps.list`, the desktop picks the first registered app, and a user-installed one comes first: so installing makes mdview the effective default, as it did on `asus-vivobook` (where it had been `ai.storyteller.wordcraft.desktop`). To choose explicitly: `xdg-mime default <app>.desktop text/markdown`. To remove mdview, delete the two installed files and run the last two commands again.

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
| Drop a file on the window | Open it in this window (several files: the first here, the rest in windows of their own) |
| Ctrl+N | New document: in this window if it is empty, else in a new one |
| Ctrl+E, or the pencil button | Switch between the rendered view and the source, keeping the place |
| Ctrl+S, or the save button | Save (a new document asks for a name) |
| Ctrl+Shift+S | Save As |
| Ctrl+F, F3, Shift+F3 | Find, next, previous (Enter and Shift+Enter in the field too); works in both views |
| Ctrl+H | Replace and Replace All, in the source |
| Ctrl+L | Go to line, in the source |
| Esc | Close the find bar |
| Ctrl+Z, Ctrl+Shift+Z, Ctrl+X/C/V/A | Undo, redo, cut, copy, paste, select all (the text view's own) |
| Tab | Four spaces, in the source |
| Ctrl+= or Ctrl++, Ctrl+-, Ctrl+0 | Zoom in, out, and back to the GTK font size: every window, both views |
| F11 | Fullscreen |
| Click a link | Follow it (see below); hovering shows the target |
| Ctrl+W | Close the window |
| Ctrl+Q | Quit |

The menu (the header bar's last button) has New, Open, Save As, Find, Replace, Go to Line, Word Wrap and Quit.

The status line under the text shows the file's folder (`~` for home), then whether it is modified, the line and column while editing, and the word count (runs of text with a letter or digit, so Markdown's own marks don't count). The count is redone when typing pauses.

Only `.md` and `.markdown` files open, in any case (`README.MD` too). mdview refuses, with a dialog naming the reason, anything that:

- isn't a regular file, after following symlinks (a directory, a FIFO, a device such as `/dev/zero`); a file whose type a gvfs backend leaves unknown is let through to the capped read
- is over 8 MiB
- holds a NUL byte
- isn't valid UTF-8

A refused file never replaces the document already showing.

## Editing and saving

The window opens on the rendered document; Ctrl+E shows the source, the exact text that is saved, and back. Switching keeps the source line at the top of the view, and the view is only re-rendered when it is shown after an edit. A modified document has a dot before its name in the title.

Unsaved work is never lost silently. Closing a window, quitting, opening another file over it, or dropping one on it asks Save, Discard or Cancel; quit asks each window in turn and stops at the first Cancel. A file being opened is read and checked before that prompt, so one that fails to open costs nothing.

Saving writes the text byte for byte, line endings included. Before writing, mdview re-reads the file and compares it with what it last read or wrote (a hash of the bytes, because the etag is only the modification time), and writes with the etag taken just before that read; a `touch` alone isn't a conflict, and a file that has become something other than a regular file isn't written. One save runs at a time. If anything else changed the file, it asks: Overwrite, or Cancel and use Save As. Save As adds `.md` to a name without an extension, refuses any other extension, and asks before replacing an existing file the file dialog didn't ask about. A save that fails says why; where gio rewrites a file in place (a symlink, a hard link, a file in a read-only folder, or one owned by another user or group), it also warns the file may be incomplete.

Autosave (below) also keeps a copy of unsaved work, so a crash, a `kill` or a forced logout costs at most about five seconds of typing.

While a document is open, mdview watches its file. A change from outside reloads a document with nothing unsaved, keeping its place; a document with unsaved work gets a bar instead, offering Reload or Keep Mine. mdview's own saves are recognised by their hash and ignored.

## Autosave and crash recovery

mdview never saves the document's own file unasked. Instead, about five seconds after typing, it writes a copy of each window's unsaved work to its recovery folder:

- `~/.local/state/mdview/recovery/` (under `$XDG_STATE_HOME` when that is set), or `recovery-devel/` for a debug build
- one file per window, `<uuid>.md`: a header line, then the text byte for byte
- mode `0600` in a `0700` folder, written to a temporary file, synced and renamed into place

A copy is deleted when its window has nothing unsaved again (a save, a reload, an undo back to the saved text) and when the window closes or mdview quits. A clean quit leaves no copy: only the `lock` file, and `failed/` if anything was ever moved there. Copies remain after a crash, a `kill`, a SIGTERM or the session ending, which is the point.

The next start reopens each copy in a window of its own, in the source view, marked modified, under a bar: **Keep** the recovered text, or **Discard** it and reload the file (or, for a new document or a file that has since gone, close the window). The bar says when the copy was made, and adds a note if the file has changed on disk since, or no longer exists. If the file now holds exactly the recovered text, the window simply opens clean.

A copy that reopens and then crashes again within ten seconds, twice, is moved to `failed/` in the recovery folder instead of being opened a third time, and a dialog says where it is, with an Open Folder button. Each file there is the text after one header line. Also moved there, with the same dialog: a copy that isn't a regular file or can't be decoded, an older copy of a file that has a newer one, and a text the text view can't hold exactly.

The status line shows "Autosave off", with the reason as a tooltip, when:

- another mdview already holds the recovery folder's lock: one running in another login session of the same user, say, since within a session a second launch hands its files to the first
- the recovery folder can't be created or read, is a symlink or not your own (a mode wider than `0700` is tightened, not refused), or any part of its path isn't on a local filesystem (ext4, btrfs, xfs, f2fs, bcachefs, zfs, tmpfs, vfat, exfat, ntfs3 and the ext2/3 relatives). So a home on NFS, FUSE or `ecryptfs` runs without autosave, and so does a session whose root filesystem is an `overlay` (toolbox, distrobox), even when the home folder itself is local.
- a copy couldn't be read, moved, opened for writing or updated at startup; those are left for a later start

"Autosave failed" shows when a copy couldn't be written, or has taken over 30 seconds to write, which is retried every five seconds; or couldn't be deleted, in which case it reopens at the next start. "Too large to autosave" shows for a document over 8 MiB, or one whose path is too long for the copy's header.

To clear everything, quit mdview and delete the recovery folder. Deleting it while mdview runs isn't supported.

A recovered file is treated cautiously until its path is found to be on a local filesystem: until then it isn't watched for outside changes, file dialogs don't start in its folder, and it is matched to other windows by URI only. The design, and what it doesn't cover (an unencrypted copy of a document from an encrypted mount, power cuts beyond what `fsync` promises), are in [mdview-plan.md](mdview-plan.md#phase-4-design).

## Rendering and links

What renders: CommonMark, plus GFM tables, task lists and strikethrough, and YAML front matter as a dimmed block. Raw and inline HTML, HTML comments, math and footnote syntax show as literal text, and an image shows as its alt text in italics. mdview never loads image files or touches the network itself.

Links, in the rendered view and in tables (`src/link.rs`): a relative or `file:` link to a `.md` or `.markdown` file opens in the same window, after the unsaved-work prompt; its `#fragment` and `?query` are dropped and percent-escapes decoded, and it resolves against the document's folder. `http`, `https` and `mailto` links go to the desktop through `gtk::UriLauncher` (and so the portal). Anything else does nothing: in-page anchors, other schemes, other file types, and relative links in a new document that has no folder yet. GTK never launches a link by itself.

## How it follows the theme

There are no colour literals. `mdview/style.css` uses only named colours from Nordic's gtk-4.0 sheet (`theme_fg_color`, `theme_bg_color`, `theme_selected_bg_color`, `theme_selected_fg_color`, `insensitive_fg_color`, `borders`). It loads at `STYLE_PROVIDER_PRIORITY_USER + 1`, because KDE's `~/.config/gtk-4.0/gtk.css` imports Nordic at USER priority and would otherwise override it.

The rendered view is one read-only `TextView`. The reading column is centred by a tag spanning the whole text, not by the view's own margins, which would count toward the window's minimum width and stop it shrinking. Text tags take colour values rather than CSS. So the window keeps hidden probe widgets and copies their computed colours into the tags: a `LinkButton` for the theme's link colour (Nordic has no named one), and labels that `style.css` gives the dim, tint and selection colours. On 2026-11-27 the first three returned `rgb(94,129,172)`, `rgb(142,149,164)` and `rgba(216,222,233,0.07)`, which are Nordic's own values.

The current search match is a tag in the theme's selection colours, not just the selection: a `TextView` only draws its selection while it has focus, and during a search the focus is in the find field.

Tables are `Grid`s anchored in the text, sized on every width change to their natural width (capped at the reading column) and to the height their cells wrap to at that width. A `TextView` would otherwise give an anchored widget its minimum size. Cells wrap only between words, so a table that can't fit even then (a 30-column one, say) scrolls sideways inside the column rather than breaking its cells into single characters. A table's forced minimum width counts toward the window's, so it is set one indent step under the room the table has: a full-width table stops that step short of the column's right edge, and in exchange the window can always be narrowed, a step per layout pass.

A theme or font change needs a restart: GTK4 reads the user `gtk.css` once (GNOME/gtk#3409), and the tag colours and the column's measurements are taken when a document is shown.

## Code

| File | Holds |
| --- | --- |
| `src/main.rs` | The application, its app id, accelerators, the quit action, the stylesheet, and the recovery scan at startup |
| `src/render.rs` | Markdown to text, styled character ranges, tables and each block's source line: pure Rust, no GTK, and most of the tests |
| `src/file.rs` | The strict checks, the capped read, guarded saves and the Save As name rule |
| `src/link.rs` | What a link click does: pure apart from glib's URI helpers, and unit-tested |
| `src/find.rs` | The find, replace and go-to-line bar, and the search and replace functions |
| `src/recovery.rs` | Recovery copies: the folder and its lock, the copy format, the local-filesystem test, each window's write slot, and the startup scan; the pure parts unit-tested |
| `src/window.rs` | Windows: the rendered view and the editor, open, drop, new, save, the prompts, the file watch, the switch between views, autosave and the recovered windows |
| `style.css` | The only stylesheet |

## Build time

Measured on `asus-vivobook` (16 threads, Rust 1.100.0) on 2026-11-27, from `cargo clean`:

| Build | Time |
| --- | --- |
| Cold dev build | 30.6 s |
| Dev rebuild after an edit | 0.24 s |
| Cold release build | 34.2 s |
| Release rebuild after an edit | 0.25 s |
| Cold `dist` build (LTO, one codegen unit) | 44.2 s |

The release profile optimises for size (`opt-level = "s"`) and aborts on panic. Measured on 2026-11-27 with Phase 4 in, that took the release binary from 1,309,176 bytes to 1,073,336, and the `dist` binary from 1,129,352 to 938,560, with no cost to the cold build and a rebuild 0.03 s slower. Rendering all of `docs/archival.md` (160,663 characters) went from 0.54 ms to 0.79 ms, still far inside a frame; GTK's own drawing is in its C libraries and unaffected. A panic inside a GTK callback aborts anyway; the setting only changes the thread-pool jobs (the autosave write, the recovered-file check and a folder sync), whose panic now ends the app (the last written copy, if any, reopens at the next start). Before, an autosave write's panic showed "Autosave failed" and the other two were ignored. Phase 3's release binary, with the default profile, was 967,856 bytes.

Nearly all the cold time is gtk-rs's serial chain (glib, gio, pango, gdk4, gsk4, gtk4); none of it can be trimmed from this side, as the plan's Non-functional section records.

## Checks

`cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` and `cargo test --locked` (47 unit tests, in `render.rs`, `file.rs`, `link.rs` and `recovery.rs`). The pre-commit hook runs the first two whenever a commit touches `mdview/`, and `.github/workflows/mdview.yml` runs all three. CI is a single job with no release artifact: a GTK app is tried on the desktop, not downloaded from a run. [repo-tooling.md](repo-tooling.md) covers the hook and the workflow.

Phase 1 manual check on `asus-vivobook`, KDE Plasma on Wayland, 2026-11-27, all passed:

- The window uses Nordic: header bar, window buttons, Noto Sans, dark mode, and the empty state.
- `docs/archival.md` (154,149 characters) renders in 4 ms and fills the view in 13 ms in a debug build, with no stall.
- A fixture with every block type renders correctly: front matter, headings, inline styles, a hard break, nested and numbered lists, task boxes, a quote, a code block, a wide and a narrow table, a rule, HTML and an image's alt text.
- A FIFO, a symlink to `/dev/zero`, a NUL file, a Latin-1 file, a `.txt` file, a directory named `dir.md`, a 9 MiB file and a missing file are each refused with a dialog, and the app stays up. `README.MD` opens.
- A second launch hands its file to the running copy, and an empty window is reused. `mdview a.md a.md` opens one window, not two.
- A 30-column table scrolls sideways with whole words in its cells, and GTK logs nothing. With it showing, the view's minimum width is 629 px in a 900 px window, so the window isn't pinned.
- In a list item, wrapped lines, later paragraphs, code blocks and tables all line up with the item's text, and tables inside quotes and items are indented with them.

Phase 2 check on `asus-vivobook`, 2026-11-27, all passed. Synthesised keystrokes don't reach a Wayland session's windows, so an instrumented copy was driven through its real actions over the session bus (`org.gtk.Actions`), with the prompts answered by script:

- Edit and save round trip on a file with a BOM, CRLF and LF mixed and no final newline: the file is exactly the typed character plus the original bytes (`cmp`).
- An outside change to an unmodified document reloads it silently, keeping its place.
- An outside edit that restores the old modification time, made while there is unsaved work, shows the changed-on-disk bar; saving then asks; Cancel leaves the outside version on disk, and Overwrite writes the user's.
- Quit with two modified windows asks twice; Discard both quits and writes nothing. Quit answered Save saves, then quits. Cancel keeps the app running.
- Replace All rewrites every match, and one undo reverts all of it.
- Switching views deep in `docs/archival.md` lands on source line 514 both ways, on the same paragraph.
- Two overlapping saves: the second is refused while the first runs, with no false conflict. A `touch` before saving isn't a conflict. A file swapped for a FIFO is refused at save time ("it isn't a regular file") with no hang.
- The find bar, the changed-on-disk bar and the match highlight are drawn in the theme, in both views.

Phase 3 check on `asus-vivobook`, 2026-11-27, all passed, the same way:

- A relative link with a `%20` escape and a `#fragment` opens the file in the same window; with unsaved work it asks first, and Cancel keeps the document. A link to a `.sh` file, and a relative link in a new document, do nothing.
- Zoom to 125%: text, headings, code and tables scale together and the column re-centres. Reset returns to the GTK size.
- The status line shows the folder and word count, and while editing "Modified · Ln 1, Col 7 · 110 words".
- F11 hides the header bar and back.
- Installed to `~/.local`: launched through its desktop entry (`gtk-launch io.github.kartikakolia.mdview`), the release build runs as `io.github.kartikakolia.mdview` and renders this doc; `gio mime text/markdown` lists it.
- The 19 phase 2 checks still pass.

Phase 4 check on `asus-vivobook`, 2026-11-27, all passed, the same way, each run with `XDG_STATE_HOME` in a scratch folder:

- Typing makes a copy within about five seconds, `0600` in a `0700` folder. `kill -9` keeps it, and the next start reopens it modified, in the source view, under the bar, and then watches the file.
- Keep, then Save, deletes the copy; closing then leaves only `lock`. Discard reloads the file and deletes the copy. A recovered new document's Discard closes its window.
- Two starts that crash within ten seconds move the copy to `failed/`, and no window opens for it; a start that stays up ten seconds resets the count to 0.
- The recovered file given as an argument opens no second window. SIGTERM leaves the copy.
- An outside change since the copy adds the "changed on disk since" note; a file that already holds the recovered text opens clean, and its copy goes.
- With the lock held by another process, "Autosave off" shows, in an empty window too, and nothing is written.
- Quit answered Discard leaves only `lock`. An undo back to the saved text deletes the copy. After Discard on one window and Cancel on the next during a quit, the first window's later typing is still autosaved.
- The recovered bar, the failed-copies dialog and the status note are drawn in the theme.
- The 19 phase 2 and 5 phase 3 checks still pass.

## Manual checklist

These need a person at the keyboard and mouse; tick them off on a new build:

- [ ] Ctrl+O, Ctrl+N, Ctrl+S, Ctrl+Shift+S, Ctrl+E, Ctrl+F/F3/Shift+F3, Ctrl+H, Ctrl+L, Esc, zoom keys, F11, Ctrl+W, Ctrl+Q all do what the table says
- [ ] The Save, Discard and Cancel prompt looks right in Nordic, and Alt+S, Alt+D and Alt+C answer it
- [ ] The Open and Save As dialogs come up through the KDE portal; New, type, Ctrl+S asks for a name and adds `.md`
- [ ] Dropping one file from Dolphin opens it; dropping three opens the other two in new windows
- [ ] Clicking a link follows it; dragging across one selects text instead; the pointer and tooltip change over a link; a web link opens the browser
- [ ] Tab inserts four spaces; Go to Line jumps, and a non-number turns the field red; Word Wrap toggles
- [ ] mdview is in the KDE menu, and in Dolphin's "Open with" for a `.md` file
- [ ] Logging out of Plasma with unsaved work: mdview's prompt appears; if the logout is forced anyway, the next start reopens the work
