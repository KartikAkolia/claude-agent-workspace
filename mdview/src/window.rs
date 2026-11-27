//! One window per document: the rendered view and the source editor, opening and saving, the
//! unsaved-work prompts, and watching the file for outside changes.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gtk::prelude::*;
use gtk::{gdk, gio, glib, pango};

use crate::file::{self, Guard, LoadError, Loaded, SaveError};
use crate::find::{self, Bar, Mode};
use crate::link::{self, Target};
use crate::recovery;
use crate::render::{self, ANCHOR, BULLETS, Marker, Rendered, Style, TASK_BOXES};

thread_local! {
    /// Every open window, so a file that is already open is focused rather than opened twice.
    static WINDOWS: RefCell<Vec<Rc<Win>>> = const { RefCell::new(Vec::new()) };
}

thread_local! {
    /// The recovery folder while autosave is on, or why it is off (recovery::start).
    static AUTOSAVE: RefCell<Result<PathBuf, String>> =
        RefCell::new(Err("autosave hasn't started".to_owned()));
    /// The copies startup found, reopened at the first activate or open, and how many it moved
    /// to `failed/`.
    static RECOVERED: RefCell<Vec<recovery::Recovered>> = const { RefCell::new(Vec::new()) };
    static FAILED: Cell<usize> = const { Cell::new(0) };
    /// A quit is asking about windows.
    static QUITTING: Cell<bool> = const { Cell::new(false) };
}

/// Records what startup found, before any window exists.
pub fn set_recovery(start: recovery::Startup) {
    let state = match start.off {
        None => Ok(recovery::folder()),
        Some(reason) => Err(reason),
    };
    AUTOSAVE.set(state);
    RECOVERED.set(start.recovered);
    FAILED.set(start.failed);
}

/// At shutdown, after the main loop: the final deletes' folder `fsync`, synchronously.
pub fn sync_recovery() {
    if let Some(dir) = recovery_dir() {
        let _ = recovery::sync_folder(&dir);
    }
}

fn recovery_dir() -> Option<PathBuf> {
    AUTOSAVE.with_borrow(|a| a.as_ref().ok().cloned())
}

/// Opens the recovered copies, once: before any file argument, so `showing()` finds them.
fn reopen_recovered(app: &gtk::Application) {
    for copy in RECOVERED.take() {
        Win::recover(app, copy);
    }
    let failed = FAILED.replace(0);
    if failed > 0 {
        // Once the first window exists, so the notice always has a parent.
        glib::idle_add_local_once(move || failed_notice(failed));
    }
}

/// Says where the copies that couldn't be reopened are kept.
fn failed_notice(count: usize) {
    let Some(window) = WINDOWS.with_borrow(|ws| ws.first().map(|w| w.window.clone())) else {
        return;
    };
    let folder = gio::File::for_path(recovery::folder().join("failed"));
    let copies = if count == 1 {
        "1 copy".to_owned()
    } else {
        format!("{count} copies")
    };
    let dialog = gtk::AlertDialog::builder()
        .modal(true)
        .message("Some recovered text couldn't be reopened")
        .detail(format!(
            "mdview kept {copies} in {}. Each is the text after one header line. Delete them \
             when you no longer need them.",
            home_relative(&folder)
        ))
        .buttons(["_Close", "_Open Folder"])
        .cancel_button(0)
        .default_button(1)
        .build();
    glib::spawn_future_local(async move {
        if let Ok(1) = dialog.choose_future(Some(&window)).await {
            let launcher = gtk::FileLauncher::new(Some(&folder));
            let _ = launcher.launch_future(Some(&window)).await;
        }
    });
}

/// Presents a window: the first one open, or a new, empty one.
pub fn activate(app: &gtk::Application) {
    reopen_recovered(app);
    let first = WINDOWS.with_borrow(|ws| ws.first().cloned());
    first.unwrap_or_else(|| Win::new(app)).window.present();
}

/// Opens a file from the command line or the desktop: in the window already showing it, else in
/// an empty window, else in a new one.
pub fn open(app: &gtk::Application, file: gio::File) {
    reopen_recovered(app);
    if let Some(win) = showing(&file, false) {
        win.window.present();
        return;
    }
    let empty = WINDOWS.with_borrow(|ws| ws.iter().find(|w| w.is_empty()).cloned());
    let win = empty.unwrap_or_else(|| Win::new(app));
    win.window.present();
    win.load(file, true);
}

/// Quits after asking about each window's unsaved work in turn; a Cancel anywhere stops it.
/// GTK's own quit skips the windows' close requests, so it is only called once all agree.
pub fn quit(app: &gtk::Application) {
    // One quit at a time: a second Ctrl+Q while one is asking would ask about the same windows.
    if QUITTING.replace(true) {
        return;
    }
    let app = app.clone();
    glib::spawn_future_local(async move {
        // Asked again until none is left: a prompt only blocks its own window, so another can
        // be edited, or opened, while one is waiting.
        loop {
            let next = WINDOWS.with_borrow(|ws| ws.iter().find(|w| w.unsaved()).cloned());
            let Some(win) = next else {
                break;
            };
            if !win.confirm_discard().await {
                // A stopped quit agreed to nothing: a later one asks about every window again.
                WINDOWS.with_borrow(|ws| ws.iter().for_each(|w| w.discarded.set(None)));
                QUITTING.set(false);
                return;
            }
            // Still modified, so the answer was Discard: this quit has agreed to lose the text,
            // and its next pass mustn't ask about it again. Only a quit marks it; a close or a
            // load acts on its Discard at once (a superseded load's Discard does nothing).
            if win.has_work() {
                win.discarded.set(Some(win.edits.get()));
            }
        }
        // GTK's quit closes no window, so each copy is deleted here (delete rule 2).
        WINDOWS.with_borrow(|ws| {
            ws.iter().for_each(|w| {
                w.closing.set(true);
                w.drop_copy(true);
            });
        });
        app.quit();
    });
}

/// Text sizes for zoom, in percent of the GTK font, and the one in use (100%).
const ZOOM_STEPS: [u32; 12] = [50, 67, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300];
const ZOOM_DEFAULT: usize = 4;

thread_local! {
    static ZOOM: Cell<usize> = const { Cell::new(ZOOM_DEFAULT) };
    static ZOOM_CSS: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
}

/// Zooms every window's text in (`1`), out (`-1`) or back to the GTK font size (`0`). A CSS
/// font size, above `style.css`'s priority, so tables and code scale with the text.
pub fn zoom(step: i32) {
    let index = match step {
        0 => ZOOM_DEFAULT,
        _ => {
            let current = ZOOM.get() as i64 + i64::from(step.signum());
            current.clamp(0, ZOOM_STEPS.len() as i64 - 1) as usize
        }
    };
    if index == ZOOM.get() && step != 0 {
        return;
    }
    ZOOM.set(index);
    let provider = ZOOM_CSS.with_borrow_mut(|css| {
        css.get_or_insert_with(|| {
            let provider = gtk::CssProvider::new();
            if let Some(display) = gdk::Display::default() {
                gtk::style_context_add_provider_for_display(
                    &display,
                    &provider,
                    gtk::STYLE_PROVIDER_PRIORITY_USER + 2,
                );
            }
            provider
        })
        .clone()
    });
    // At the default there is no rule at all, so a theme's own text size applies again.
    let css = if index == ZOOM_DEFAULT {
        String::new()
    } else {
        format!(
            "textview.md-view, textview.md-editor {{ font-size: {}%; }}",
            ZOOM_STEPS[index]
        )
    };
    provider.load_from_string(&css);
    WINDOWS.with_borrow(|ws| ws.iter().for_each(Win::refit_after_restyle));
}

/// The window showing `file`, or loading it, so a file opened twice quickly gets one window.
/// `same_file` canonicalizes, which could hang on a dead mount, so URIs alone are compared for
/// `uri_only` (a link followed from an unchecked recovered window), for a window that is itself
/// unchecked, and for any load still pending, which may be of a path nothing has checked. (So
/// one file opened twice through different symlinks while the first is loading gets two.)
fn showing(file: &gio::File, uri_only: bool) -> Option<Rc<Win>> {
    let matches = |f: &Option<gio::File>, by_uri: bool| {
        f.as_ref().is_some_and(|f| {
            if by_uri {
                f.equal(file)
            } else {
                same_file(f, file)
            }
        })
    };
    WINDOWS.with_borrow(|ws| {
        ws.iter()
            .find(|w| {
                let by_uri = uri_only || w.unchecked.get();
                matches(&w.file.borrow(), by_uri) || matches(&w.pending.borrow(), true)
            })
            .cloned()
    })
}

struct Win {
    window: gtk::ApplicationWindow,
    stack: gtk::Stack,
    scroller: gtk::ScrolledWindow,
    /// The rendered document, rebuilt from `source` when it is shown after an edit.
    view: gtk::TextView,
    editor: gtk::TextView,
    /// The document's text, exactly as it is (or will be) on disk.
    source: gtk::TextBuffer,
    bar: Bar,
    changed: InfoBar,
    /// The bar over a recovered window: Discard or Keep.
    recovered: InfoBar,
    edit_action: gio::SimpleAction,
    probes: Probes,
    /// The file, or `None` for a new document not yet saved.
    file: RefCell<Option<gio::File>>,
    /// Whether there is a document at all; an empty window has none.
    has_doc: Cell<bool>,
    /// What the file was when last read or written, for the conflict check.
    guard: RefCell<Option<Guard>>,
    monitor: RefCell<Option<gio::FileMonitor>>,
    /// The file being loaded, and a count of loads started: only the latest load's result is
    /// shown, so a slow load can't replace a newer one.
    pending: RefCell<Option<gio::File>>,
    loads: Cell<u64>,
    /// Edits to `source`: a save clears the modified flag only if none came in meanwhile.
    edits: Cell<u64>,
    /// Whether `view` is behind `source`.
    stale: Cell<bool>,
    /// Where each rendered block starts, and its source line (render::Rendered::blocks).
    blocks: RefCell<Vec<(usize, usize)>>,
    /// While a save runs, the file monitor's events are mdview's own.
    saving: Cell<bool>,
    /// Set once closing has been agreed to, so the close request lets it through.
    closing: Cell<bool>,
    /// `edits` when the user chose Discard in the quit under way, so it doesn't ask twice about
    /// the same text; cleared if that quit stops.
    discarded: Cell<Option<u64>>,
    layout: RefCell<Layout>,
    /// The rendered view's links, from render::Rendered::links.
    links: RefCell<Vec<render::Link>>,
    status: Status,
    /// The word count, recounted when idle after an edit.
    words: Cell<usize>,
    counting: Cell<bool>,
    /// A rebuild for a zoom is waiting for its frame.
    refit_pending: Cell<bool>,
    /// Names this window's recovery copy, `<uuid>.md`; the slot it shares with its writes.
    uuid: String,
    slot: recovery::SlotRef,
    /// The copy write in flight (its sequence number), whether another is wanted after it, and
    /// whether the 5-second timer is armed.
    writing: Cell<Option<u64>>,
    write_wanted: Cell<bool>,
    timer_armed: Cell<bool>,
    /// "Autosave failed" or "Too large to autosave", with the reason, for the status line.
    note: RefCell<Option<(&'static str, String)>>,
    /// A recovered file not yet found local: matched by URI only, and not watched.
    unchecked: Cell<bool>,
    /// Successful saves, so the recovered-file check can tell one happened meanwhile.
    saves: Cell<u64>,
    /// Save, Discard or Cancel prompts open on this window: a count, since a close and a quit
    /// can each ask at once.
    asking: Cell<u32>,
}

/// The status line under the text: the file's folder, then whether it is modified, the line
/// and column while editing, and the word count.
struct Status {
    bar: gtk::Box,
    folder: gtk::Label,
    details: gtk::Label,
    /// "Autosave off" and the like, with the reason as its tooltip.
    note: gtk::Label,
}

/// A bar over the text with an action and a keep button: the changed-on-disk bar (Reload,
/// Keep Mine) and the recovered bar (Discard, Keep).
struct InfoBar {
    revealer: gtk::Revealer,
    label: gtk::Label,
    act: gtk::Button,
    keep: gtk::Button,
}

/// Hidden widgets whose computed colours become the tag colours: tags take colour values, not
/// CSS, and this way the colours still come from the theme. `style.css` styles the labels;
/// the link button carries the theme's own link colour (Nordic has no named one).
struct Probes {
    link: gtk::LinkButton,
    dim: gtk::Label,
    tint: gtk::Label,
    match_bg: gtk::Label,
    match_fg: gtk::Label,
}

/// What a resize has to adjust: the reading column is centred, so every margin moves with it.
#[derive(Default)]
struct Layout {
    /// The widest the text column gets, and the smallest side margin.
    measure: i32,
    min_margin: i32,
    /// One indent level.
    step: i32,
    /// Spans the whole text and carries the centring margins. Tag margins, unlike the view's
    /// own, don't count toward the view's minimum width, so centring never pins the window.
    column: Option<gtk::TextTag>,
    /// Indent tags with their offset from the column's left edge.
    indents: Vec<(gtk::TextTag, i32)>,
    /// Each table with the indent level it sits at.
    tables: Vec<(gtk::ScrolledWindow, u8)>,
    /// The width last laid out for, so an unchanged width costs nothing.
    width: Cell<i32>,
}

impl Win {
    fn new(app: &gtk::Application) -> Rc<Self> {
        Self::build(app, glib::uuid_string_random().into(), 0)
    }

    fn build(app: &gtk::Application, uuid: String, attempts: u8) -> Rc<Self> {
        let view = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        view.add_css_class("md-view");
        let scroller = scrolled(&view);

        let editor = gtk::TextView::builder()
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        editor.add_css_class("md-editor");
        let source = editor.buffer();

        let stack = gtk::Stack::new();
        stack.add_named(&empty_page(), Some("empty"));
        stack.add_named(&scroller, Some("view"));
        stack.add_named(&scrolled(&editor), Some("edit"));

        let probes = Probes {
            link: gtk::LinkButton::new("about:blank"),
            dim: probe_label("md-probe-dim"),
            tint: probe_label("md-probe-tint"),
            match_bg: probe_label("md-probe-match-bg"),
            match_fg: probe_label("md-probe-match-fg"),
        };
        let probe_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        probe_box.append(&probes.link);
        probe_box.append(&probes.dim);
        probe_box.append(&probes.tint);
        probe_box.append(&probes.match_bg);
        probe_box.append(&probes.match_fg);
        probe_box.set_visible(false);

        let bar = Bar::new();
        let changed = InfoBar::new("Reload", "Keep Mine");
        let recovered = InfoBar::new("Discard", "Keep");
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&bar.revealer);
        content.append(&recovered.revealer);
        content.append(&changed.revealer);
        content.append(&stack);
        let status = Status::new();
        content.append(&status.bar);
        content.append(&probe_box);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("mdview")
            .default_width(900)
            .default_height(1000)
            .titlebar(&header_bar())
            .child(&content)
            .build();

        let win = Rc::new(Self {
            window,
            stack,
            scroller,
            view,
            editor,
            source,
            bar,
            changed,
            recovered,
            edit_action: gio::SimpleAction::new_stateful("edit", None, &false.to_variant()),
            probes,
            file: RefCell::new(None),
            has_doc: Cell::new(false),
            guard: RefCell::new(None),
            monitor: RefCell::new(None),
            pending: RefCell::new(None),
            loads: Cell::new(0),
            edits: Cell::new(0),
            stale: Cell::new(true),
            blocks: RefCell::new(Vec::new()),
            saving: Cell::new(false),
            closing: Cell::new(false),
            discarded: Cell::new(None),
            layout: RefCell::new(Layout::default()),
            links: RefCell::new(Vec::new()),
            status,
            words: Cell::new(0),
            counting: Cell::new(false),
            refit_pending: Cell::new(false),
            uuid,
            slot: recovery::new_slot(attempts),
            writing: Cell::new(None),
            write_wanted: Cell::new(false),
            timer_armed: Cell::new(false),
            note: RefCell::new(None),
            unchecked: Cell::new(false),
            saves: Cell::new(0),
            asking: Cell::new(0),
        });
        win.connect_actions();
        win.connect_editor();
        win.connect_bars();
        win.connect_window();
        win.update_actions();
        // Empty, the status line shows only "Autosave off", if that.
        win.update_status();
        WINDOWS.with_borrow_mut(|ws| ws.push(win.clone()));
        win
    }

    /// Unsaved work, while the window's close isn't agreed: what autosave keeps a copy of.
    /// Text the user chose to discard counts while it is still in the window, since a quit
    /// cancelled at another window leaves it open.
    fn has_work(&self) -> bool {
        self.has_doc.get() && self.source.is_modified() && !self.closing.get()
    }

    /// Unsaved work the quit under way hasn't already been told to discard: what it asks about.
    fn unsaved(&self) -> bool {
        self.has_work() && self.discarded.get() != Some(self.edits.get())
    }

    fn is_empty(&self) -> bool {
        !self.has_doc.get() && self.pending.borrow().is_none()
    }

    fn editing(&self) -> bool {
        self.stack.visible_child_name().as_deref() == Some("edit")
    }

    /// The view on screen: find works on this one.
    fn active(&self) -> &gtk::TextView {
        if self.editing() {
            &self.editor
        } else {
            &self.view
        }
    }

    fn source_text(&self) -> String {
        let (start, end) = self.source.bounds();
        self.source.text(&start, &end, true).into()
    }

    /// The window's actions. Each closure holds the window weakly: the window owns them.
    fn connect_actions(self: &Rc<Self>) {
        self.action("open", |win| win.choose_file());
        self.action("close", |win| win.window.close());
        self.action("new", |win| win.new_document());
        self.action("save", |win| {
            glib::spawn_future_local(async move {
                win.save().await;
            });
        });
        self.action("save-as", |win| {
            glib::spawn_future_local(async move {
                win.save_as().await;
            });
        });
        self.action("find", |win| win.open_bar(Mode::Find));
        self.action("replace", |win| {
            win.set_editing(true);
            win.open_bar(Mode::Replace);
        });
        self.action("goto", |win| {
            win.set_editing(true);
            win.open_bar(Mode::GoTo);
        });
        self.action("find-next", |win| win.find_again(true));
        self.action("find-previous", |win| win.find_again(false));

        let weak = Rc::downgrade(self);
        self.edit_action.connect_activate(move |action, _| {
            let on = action
                .state()
                .and_then(|s| s.get::<bool>())
                .unwrap_or(false);
            if let Some(win) = weak.upgrade() {
                win.set_editing(!on);
            }
        });
        self.window.add_action(&self.edit_action);

        let wrap = gio::SimpleAction::new_stateful("wrap", None, &true.to_variant());
        let editor = self.editor.downgrade();
        wrap.connect_activate(move |action, _| {
            let on = !action.state().and_then(|s| s.get::<bool>()).unwrap_or(true);
            action.set_state(&on.to_variant());
            if let Some(editor) = editor.upgrade() {
                let mode = if on {
                    gtk::WrapMode::WordChar
                } else {
                    gtk::WrapMode::None
                };
                editor.set_wrap_mode(mode);
            }
        });
        self.window.add_action(&wrap);

        let fullscreen = gio::SimpleAction::new_stateful("fullscreen", None, &false.to_variant());
        let window = self.window.downgrade();
        fullscreen.connect_activate(move |_, _| {
            if let Some(window) = window.upgrade() {
                window.set_fullscreened(!window.is_fullscreen());
            }
        });
        // The window manager can change it too, so the state follows the window.
        let action = fullscreen.downgrade();
        self.window.connect_fullscreened_notify(move |window| {
            if let Some(action) = action.upgrade() {
                action.set_state(&window.is_fullscreen().to_variant());
            }
        });
        self.window.add_action(&fullscreen);
    }

    fn action(self: &Rc<Self>, name: &str, run: impl Fn(Rc<Self>) + 'static) {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(self);
        action.connect_activate(move |_, _| {
            if let Some(win) = weak.upgrade() {
                run(win);
            }
        });
        self.window.add_action(&action);
    }

    /// Actions that need a document are off in an empty window.
    fn update_actions(&self) {
        let has_doc = self.has_doc.get();
        let names = [
            "save",
            "save-as",
            "find",
            "replace",
            "goto",
            "find-next",
            "find-previous",
        ];
        for name in names {
            let action = self
                .window
                .lookup_action(name)
                .and_then(|a| a.downcast::<gio::SimpleAction>().ok());
            if let Some(action) = action {
                action.set_enabled(has_doc);
            }
        }
        self.edit_action.set_enabled(has_doc);
    }

    /// A handler for a signal whose only argument is its emitter (a button's clicked, an
    /// entry's activate, a buffer's changed). It holds the window weakly, since the window owns
    /// the widget, and does nothing once the window is gone.
    fn on<T>(self: &Rc<Self>, run: impl Fn(&Rc<Self>) + 'static) -> impl Fn(&T) + 'static {
        let weak = Rc::downgrade(self);
        move |_| {
            if let Some(win) = weak.upgrade() {
                run(&win);
            }
        }
    }

    /// Runs `run` once after `delay`, if the window is still open.
    fn after(self: &Rc<Self>, delay: Duration, run: impl FnOnce(&Rc<Self>) + 'static) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(delay, move || {
            if let Some(win) = weak.upgrade() {
                run(&win);
            }
        });
    }

    fn connect_editor(self: &Rc<Self>) {
        self.source.connect_changed(self.on(|win| {
            win.edits.set(win.edits.get() + 1);
            win.stale.set(true);
            win.count_words_soon();
            win.arm_autosave();
        }));
        self.source
            .connect_cursor_position_notify(self.on(|win| win.update_status()));
        self.source.connect_modified_changed(self.on(|win| {
            // Delete rule 1: nothing unsaved, so no copy (a save, a load, or an undo back to
            // the saved text).
            if !win.source.is_modified() {
                win.drop_copy(false);
            }
            win.update_title();
        }));

        // Tab inserts four spaces: CommonMark reads a tab as up to four columns anyway, and
        // spaces show the same everywhere.
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let source = self.source.clone();
        keys.connect_key_pressed(move |_, key, _, state| {
            let modifiers = gdk::ModifierType::SHIFT_MASK
                | gdk::ModifierType::CONTROL_MASK
                | gdk::ModifierType::ALT_MASK
                | gdk::ModifierType::SUPER_MASK;
            if key != gdk::Key::Tab || state.intersects(modifiers) {
                return glib::Propagation::Proceed;
            }
            source.begin_user_action();
            source.delete_selection(true, true);
            source.insert_interactive_at_cursor("    ", true);
            source.end_user_action();
            glib::Propagation::Stop
        });
        self.editor.add_controller(keys);
    }

    fn connect_bars(self: &Rc<Self>) {
        let bar = &self.bar;
        bar.find
            .connect_search_changed(self.on(|win| win.run_find(true, true)));
        bar.find
            .connect_activate(self.on(|win| win.run_find(true, false)));
        bar.find
            .connect_next_match(self.on(|win| win.run_find(true, false)));
        bar.find
            .connect_previous_match(self.on(|win| win.run_find(false, false)));
        bar.find.connect_stop_search(self.on(|win| win.close_bar()));
        bar.next
            .connect_clicked(self.on(|win| win.run_find(true, false)));
        bar.previous
            .connect_clicked(self.on(|win| win.run_find(false, false)));
        bar.case
            .connect_toggled(self.on(|win| win.run_find(true, true)));
        bar.close.connect_clicked(self.on(|win| win.close_bar()));

        // Shift+Enter finds backwards, and Escape closes the bar from any of its fields.
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, state| {
            let Some(win) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if key == gdk::Key::Escape {
                win.close_bar();
                return glib::Propagation::Stop;
            }
            let enter = matches!(key, gdk::Key::Return | gdk::Key::KP_Enter);
            let shift = state.contains(gdk::ModifierType::SHIFT_MASK);
            if enter && shift && win.bar.find.has_focus() {
                win.run_find(false, false);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        bar.revealer.add_controller(keys);

        bar.replace
            .connect_clicked(self.on(|win| win.replace(false)));
        bar.replace_all
            .connect_clicked(self.on(|win| win.replace(true)));
        bar.replacement
            .connect_activate(self.on(|win| win.replace(false)));
        bar.line.connect_activate(
            self.on(|win| match win.bar.line.text().trim().parse::<i32>() {
                Ok(line) => {
                    win.set_editing(true);
                    find::go_to_line(&win.editor, line);
                    win.close_bar();
                }
                Err(_) => win.bar.line_error(true),
            }),
        );

        self.changed.act.connect_clicked(self.on(|win| {
            win.changed.revealer.set_reveal_child(false);
            let file = win.file.borrow().clone();
            if let Some(file) = file {
                win.load(file, false);
            }
        }));
        self.changed
            .keep
            .connect_clicked(self.on(|win| win.changed.revealer.set_reveal_child(false)));
        self.recovered
            .act
            .connect_clicked(self.on(|win| win.discard_recovered()));
        self.recovered
            .keep
            .connect_clicked(self.on(|win| win.recovered.revealer.set_reveal_child(false)));
    }

    /// The file drop, the resize hook, link clicks and the close request.
    fn connect_window(self: &Rc<Self>) {
        // A click on a link follows it, unless the click ended a selection.
        let click = gtk::GestureClick::new();
        click.set_button(gdk::BUTTON_PRIMARY);
        let weak = Rc::downgrade(self);
        click.connect_released(move |_, presses, x, y| {
            let Some(win) = weak.upgrade() else {
                return;
            };
            if presses != 1 || win.view.buffer().has_selection() {
                return;
            }
            if let Some(url) = win.link_at(x, y) {
                win.open_link(&url);
            }
        });
        self.view.add_controller(click);
        // Over a link: a pointing hand, and the target as a tooltip.
        let motion = gtk::EventControllerMotion::new();
        let weak = Rc::downgrade(self);
        motion.connect_motion(move |_, x, y| {
            let Some(win) = weak.upgrade() else {
                return;
            };
            let url = win.link_at(x, y);
            win.view
                .set_cursor_from_name(Some(if url.is_some() { "pointer" } else { "text" }));
            win.view.set_tooltip_text(url.as_deref());
        });
        self.view.add_controller(motion);

        // Capture phase, so a file dropped on the text opens rather than being read as text.
        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        drop.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        // The first dropped file opens here, any others in windows of their own.
        drop.connect_drop(move |_, value, _, _| {
            let files = value
                .get::<gdk::FileList>()
                .map(|l| l.files())
                .unwrap_or_default();
            let mut files = files.into_iter();
            let (Some(win), Some(first)) = (weak.upgrade(), files.next()) else {
                return false;
            };
            win.open_here(first, false);
            if let Some(app) = win.window.application() {
                files.for_each(|file| open(&app, file));
            }
            true
        });
        self.window.add_controller(drop);

        // GTK4 has no resize signal; the scroller's horizontal page size is its width.
        self.scroller
            .hadjustment()
            .connect_page_size_notify(self.on(|win| win.relayout()));

        // Unsaved work holds the close until the prompt is answered.
        let weak = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            let Some(win) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if win.closing.get() || !win.has_doc.get() || !win.source.is_modified() {
                // Delete rule 2: a closing window leaves no copy, and none can land after.
                win.drop_copy(true);
                WINDOWS.with_borrow_mut(|ws| ws.retain(|w| &w.window != window));
                return glib::Propagation::Proceed;
            }
            glib::spawn_future_local(async move {
                if win.confirm_discard().await {
                    win.closing.set(true);
                    win.window.close();
                }
            });
            glib::Propagation::Stop
        });
    }

    fn choose_file(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::builder()
            .title("Open Markdown file")
            .modal(true)
            .build();
        self.prepare_dialog(&dialog);
        let weak = Rc::downgrade(self);
        let window = self.window.clone();
        glib::spawn_future_local(async move {
            // Cancelling the dialog is an error too; there is nothing to report for it.
            let Ok(file) = dialog.open_future(Some(&window)).await else {
                return;
            };
            if let Some(win) = weak.upgrade() {
                win.open_here(file, false);
            }
        });
    }

    /// The target of the link under a point in the rendered view, in widget coordinates.
    fn link_at(&self, x: f64, y: f64) -> Option<String> {
        let (bx, by) =
            self.view
                .window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let at = self.view.iter_at_location(bx, by)?;
        let offset = usize::try_from(at.offset()).ok()?;
        self.links
            .borrow()
            .iter()
            .find(|l| l.start <= offset && offset < l.end)
            .map(|l| l.url.clone())
    }

    /// Follows a link (link::resolve): a Markdown file opens here, after the unsaved-work
    /// prompt; a web or mail link goes to the desktop; anything else does nothing.
    fn open_link(self: &Rc<Self>, href: &str) {
        let folder = self
            .file
            .borrow()
            .as_ref()
            .and_then(|f| f.parent())
            .filter(|f| self.may_ask_path(f))
            .and_then(|f| f.path());
        match link::resolve(href, folder.as_deref()) {
            Target::Markdown(path) => {
                let target = gio::File::for_path(path);
                // A link to this same document (`README.md#usage` inside README.md) is an
                // in-page jump, which does nothing, as `#usage` alone does. In an unchecked
                // recovered window the target is in an unchecked folder: URIs only.
                let uri_only = self.unchecked.get();
                let here = self.file.borrow().as_ref().is_some_and(|f| {
                    if uri_only {
                        f.equal(&target)
                    } else {
                        same_file(f, &target)
                    }
                });
                if !here {
                    self.open_here(target, uri_only);
                }
            }
            Target::External(uri) => {
                let launcher = gtk::UriLauncher::new(&uri);
                let weak = Rc::downgrade(self);
                let window = self.window.clone();
                glib::spawn_future_local(async move {
                    let Err(e) = launcher.launch_future(Some(&window)).await else {
                        return;
                    };
                    // Closing the "open with" chooser isn't a failure.
                    let dismissed = e.matches(gtk::DialogError::Dismissed)
                        || e.matches(gtk::DialogError::Cancelled);
                    if let (false, Some(win)) = (dismissed, weak.upgrade()) {
                        win.alert(&format!("Couldn't open {uri}"), &sentence(e.message()));
                    }
                });
            }
            Target::Nothing => {}
        }
    }

    /// Opens a file in this window, unless another window already shows it.
    fn open_here(self: &Rc<Self>, file: gio::File, uri_only: bool) {
        match showing(&file, uri_only) {
            Some(other) if !Rc::ptr_eq(&other, self) => other.window.present(),
            _ => self.load(file, true),
        }
    }

    /// Loads, validates, asks about unsaved work, then swaps: a file that fails to load never
    /// costs the current one. Without `ask` it is a reload of the same file, which the user has
    /// asked for (or which has nothing unsaved), and keeps the place in the document.
    fn load(self: &Rc<Self>, file: gio::File, ask: bool) {
        let edits = self.edits.get();
        let this_load = self.loads.get() + 1;
        self.loads.set(this_load);
        self.pending.replace(Some(file.clone()));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = file::load(&file).await;
            let Some(win) = weak.upgrade() else {
                return;
            };
            if win.loads.get() != this_load {
                return; // A newer load superseded this one.
            }
            match result {
                Err(reason) => {
                    win.pending.replace(None);
                    win.alert(
                        &format!("Couldn't open “{}”", display_name(&file)),
                        &sentence(&reason.to_string()),
                    );
                }
                Ok(loaded) => {
                    let go = !ask || win.confirm_discard().await;
                    if win.loads.get() != this_load {
                        return; // Superseded while the prompt was open.
                    }
                    win.pending.replace(None);
                    // A reload never replaces text typed while it was reading the file.
                    if !ask && win.edits.get() != edits {
                        win.show_changed(&file);
                    } else if go {
                        win.show(&file, loaded, !ask);
                    }
                }
            }
        });
    }

    fn show(self: &Rc<Self>, file: &gio::File, loaded: Loaded, keep_place: bool) {
        let place = keep_place.then(|| (self.editing(), self.top_line()));
        self.set_text_irreversibly(&loaded.text);
        // file::check_text keeps out what TextBuffer refuses, but a text the buffer didn't take
        // whole must never be saved back over the file.
        let held = usize::try_from(self.source.char_count()).unwrap_or(0);
        if held != loaded.text.chars().count() {
            self.source.set_text("");
            self.source.set_modified(false);
            self.close_document();
            self.alert(
                &format!("Couldn't open “{}”", display_name(file)),
                "The text view couldn't hold its text exactly, so it isn't safe to edit.",
            );
            return;
        }
        self.source.place_cursor(&self.source.start_iter());
        self.source.set_modified(false);
        self.guard.replace(Some(loaded.guard));
        self.file.replace(Some(file.clone()));
        self.has_doc.set(true);
        // The file has just been read: an ordinary window from here on.
        self.unchecked.set(false);
        self.recovered.revealer.set_reveal_child(false);
        self.watch(file);
        self.changed.revealer.set_reveal_child(false);
        self.update_title();
        self.update_actions();
        match place {
            Some((true, line)) => self.scroll_editor_to(line),
            Some((false, line)) => {
                self.show_view();
                self.scroll_view_to(line);
            }
            None => {
                self.show_view();
                self.scroller.vadjustment().set_value(0.0);
            }
        }
    }

    /// A file dialog for Markdown files, starting in the document's folder (never an unchecked
    /// one: the portal would read it).
    fn prepare_dialog(&self, dialog: &gtk::FileDialog) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Markdown"));
        // Suffixes match without regard to case.
        filter.add_suffix("md");
        filter.add_suffix("markdown");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        dialog.set_filters(Some(&filters));
        dialog.set_default_filter(Some(&filter));
        let folder = self.file.borrow().as_ref().and_then(|f| f.parent());
        if let (false, Some(folder)) = (self.unchecked.get(), folder) {
            dialog.set_initial_folder(Some(&folder));
        }
    }

    /// Puts in a whole new text, which undo never reaches back past into the previous one.
    fn set_text_irreversibly(&self, text: &str) {
        self.source.begin_irreversible_action();
        self.source.set_text(text);
        self.source.end_irreversible_action();
    }

    /// Back to an empty window, after a document that couldn't be held.
    fn close_document(&self) {
        self.file.replace(None);
        self.guard.replace(None);
        self.monitor.replace(None);
        self.has_doc.set(false);
        self.unchecked.set(false);
        self.recovered.revealer.set_reveal_child(false);
        self.stack.set_visible_child_name("empty");
        self.edit_action.set_state(&false.to_variant());
        self.update_title();
        self.update_actions();
    }

    /// A new, unsaved document: in this window if it is empty, else in a new one.
    fn new_document(self: &Rc<Self>) {
        let win = if self.is_empty() {
            self.clone()
        } else {
            let Some(app) = self.window.application() else {
                return;
            };
            let win = Win::new(&app);
            win.window.present();
            win
        };
        win.set_text_irreversibly("");
        win.source.set_modified(false);
        win.file.replace(None);
        win.guard.replace(None);
        win.monitor.replace(None);
        win.has_doc.set(true);
        win.update_title();
        win.update_actions();
        win.set_editing(true);
    }

    fn update_title(&self) {
        let title = match (self.has_doc.get(), self.source.is_modified()) {
            (false, _) => "mdview".to_owned(),
            (true, true) => format!("• {}", self.name()),
            (true, false) => self.name(),
        };
        self.window.set_title(Some(&title));
        self.update_status();
    }

    /// Counts words once the edits pause: on idle, so typing never waits for a count.
    fn count_words_soon(self: &Rc<Self>) {
        if self.counting.replace(true) {
            return;
        }
        self.count_after_pause(self.edits.get());
    }

    /// Counts once 300 ms pass with no edit: a timer that, finding more edits since it was set,
    /// sets itself again rather than counting between keystrokes.
    fn count_after_pause(self: &Rc<Self>, edits: u64) {
        self.after(Duration::from_millis(300), move |win| {
            if win.edits.get() != edits {
                win.count_after_pause(win.edits.get());
                return;
            }
            win.counting.set(false);
            win.words.set(render::word_count(&win.source_text()));
            win.update_status();
        });
    }

    fn update_status(&self) {
        let has_doc = self.has_doc.get();
        let off = AUTOSAVE.with_borrow(|a| a.as_ref().err().cloned());
        // An empty window shows only "Autosave off", so it is never missed.
        self.status.bar.set_visible(has_doc || off.is_some());
        self.status.folder.set_visible(has_doc);
        self.status.details.set_visible(has_doc);
        let folder = self
            .file
            .borrow()
            .as_ref()
            .and_then(|f| f.parent())
            .map_or_else(|| "Not saved yet".to_owned(), |f| self.folder_name(&f));
        self.status.folder.set_text(&folder);
        let mut details = Vec::new();
        if self.source.is_modified() {
            details.push("Modified".to_owned());
        }
        if self.editing() {
            let at = self.source.iter_at_mark(&self.source.get_insert());
            details.push(format!(
                "Ln {}, Col {}",
                at.line() + 1,
                at.line_offset() + 1
            ));
        }
        let words = self.words.get();
        details.push(format!("{words} word{}", if words == 1 { "" } else { "s" }));
        self.status.details.set_text(&details.join("   ·   "));
        let note = off
            .map(|reason| ("Autosave off", reason))
            .or_else(|| self.note.borrow().clone());
        self.status.note.set_visible(note.is_some());
        if let Some((text, reason)) = note {
            let text = if has_doc {
                format!("·   {text}")
            } else {
                text.to_owned()
            };
            self.status.note.set_text(&text);
            self.status.note.set_tooltip_text(Some(&sentence(&reason)));
        }
    }

    /// After a zoom: GTK applies the new font at the next frame, and the rendered view's
    /// measurements (column, indents, tables) come from that font, so it is rebuilt a frame
    /// later, keeping the place.
    fn refit_after_restyle(self: &Rc<Self>) {
        // Several zoom steps before the next frame need only one rebuild, at the final size.
        if self.refit_pending.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        let frames = Cell::new(0);
        self.window.add_tick_callback(move |_, _| {
            frames.set(frames.get() + 1);
            if frames.get() < 2 {
                return glib::ControlFlow::Continue;
            }
            if let Some(win) = weak.upgrade() {
                win.refit_pending.set(false);
                win.stale.set(true);
                if win.editing() {
                    win.fit_editor_margins();
                } else if win.has_doc.get() {
                    let line = win.top_line();
                    win.show_view();
                    win.scroll_view_to(line);
                    if win.bar.is_open() {
                        win.run_find(true, true);
                    }
                }
            }
            glib::ControlFlow::Break
        });
    }

    /// Whether `path()` may be asked of a file on the main thread. For an unchecked recovered
    /// window's non-`file:` URI it would ask gvfsd over D-Bus, so it isn't; a `file:` URI's
    /// path is only its text.
    fn may_ask_path(&self, file: &gio::File) -> bool {
        !self.unchecked.get() || file.has_uri_scheme("file")
    }

    /// The folder for the status line: `~`-relative, or the URI while it can't be asked.
    fn folder_name(&self, folder: &gio::File) -> String {
        if self.may_ask_path(folder) {
            home_relative(folder)
        } else {
            folder.uri().into()
        }
    }

    fn name(&self) -> String {
        self.file
            .borrow()
            .as_ref()
            .map_or_else(|| "Untitled".to_owned(), display_name)
    }

    /// Asks before unsaved work is lost: Save, Discard or Cancel. True to go ahead (saved or
    /// discarded), false to stay.
    async fn confirm_discard(self: &Rc<Self>) -> bool {
        loop {
            // Asked again after a save that left the document modified (typing during it),
            // rather than going ahead with that typing's copy deleted; and not at all once
            // another prompt has agreed to this window's close.
            let clean = !self.has_doc.get() || !self.source.is_modified();
            if clean || self.closing.get() {
                return true;
            }
            if self.still_saving() {
                return false;
            }
            let answer = self.ask_save().await;
            // While this prompt was open, another may have closed the window (its answer then
            // stands) or started a save.
            if self.closing.get() {
                return true;
            }
            if answer.is_some() && self.still_saving() {
                return false;
            }
            match answer {
                Some(true) => {
                    if !self.save().await {
                        return false;
                    }
                }
                Some(false) => return true,
                None => return false,
            }
        }
    }

    /// A save under way, or its Save As chooser, would turn a Save away silently, and a Discard
    /// would close the window under it: so it is said instead.
    fn still_saving(&self) -> bool {
        if self.saving.get() {
            self.window.present();
            self.alert(
                "Still saving",
                "Finish or cancel the save that is under way, then try again.",
            );
        }
        self.saving.get()
    }

    /// Save (`Some(true)`), Discard (`Some(false)`) or Cancel (`None`).
    async fn ask_save(&self) -> Option<bool> {
        self.window.present();
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(format!("Save changes to “{}”?", self.name()))
            .detail("Unsaved changes will be lost if you don't save them.")
            .buttons(["_Cancel", "_Discard", "_Save"])
            .cancel_button(0)
            .default_button(2)
            .build();
        self.asking.set(self.asking.get() + 1);
        let answer = dialog.choose_future(Some(&self.window)).await;
        self.asking.set(self.asking.get() - 1);
        match answer {
            Ok(1) => Some(false),
            Ok(2) => Some(true),
            _ => None,
        }
    }

    /// Saves to the document's file, or asks for one. True once it is on disk.
    async fn save(self: &Rc<Self>) -> bool {
        // One save at a time: a second would check the file against the guard the first is
        // about to replace, and report mdview's own save as an outside change.
        let Some(_busy) = Busy::start(&self.saving) else {
            return false;
        };
        if !self.has_doc.get() {
            return false;
        }
        let file = self.file.borrow().clone();
        let Some(file) = file else {
            return self.choose_and_save().await;
        };
        let text = self.source_text();
        let edits = self.edits.get();
        let mut guard = self.guard.borrow().clone();
        let saved = loop {
            match file::save(&file, &text, guard.as_ref()).await {
                Err(SaveError::Conflict) => {
                    if !self.ask_overwrite(&file).await {
                        return false;
                    }
                    // Overwrite what is there now, and still notice a change made while the
                    // prompt was open: that asks again.
                    guard = match file::read_checked(&file).await {
                        Ok(Some(disk)) => Some(Guard::of(&disk.bytes)),
                        Ok(None) => None,
                        Err(message) => {
                            let failed = SaveError::Failed {
                                message,
                                in_place: false,
                            };
                            break self.finish_save(&file, Err(failed), edits);
                        }
                    };
                }
                result => break self.finish_save(&file, result, edits),
            }
        };
        // A copy of any typing during the save, with the new guard.
        if saved {
            self.autosave();
        }
        saved
    }

    /// Saves to a file the user picks, which then becomes the document's file.
    async fn save_as(self: &Rc<Self>) -> bool {
        let Some(_busy) = Busy::start(&self.saving) else {
            return false;
        };
        self.choose_and_save().await
    }

    /// Save As itself, for a caller that already holds the save in progress.
    async fn choose_and_save(self: &Rc<Self>) -> bool {
        if !self.has_doc.get() {
            return false;
        }
        let current = self.file.borrow().clone();
        let initial = current
            .as_ref()
            .map_or_else(|| "Untitled.md".to_owned(), display_name);
        let dialog = gtk::FileDialog::builder()
            .title("Save As")
            .modal(true)
            .initial_name(initial)
            .build();
        self.prepare_dialog(&dialog);
        let Ok(chosen) = dialog.save_future(Some(&self.window)).await else {
            return false;
        };
        let Some(name) = chosen.basename() else {
            return false;
        };
        let target = match file::save_name(&name) {
            Err(reason) => {
                let heading = format!("Couldn't save as “{}”", name.display());
                self.alert(&heading, &sentence(&reason));
                return false;
            }
            Ok(fixed) if fixed == name => chosen,
            Ok(fixed) => {
                let Some(folder) = chosen.parent() else {
                    return false;
                };
                let target = folder.child(&fixed);
                // The dialog asked about overwriting the name as typed, not this one.
                if exists(&target).await && !self.ask_replace(&target).await {
                    return false;
                }
                target
            }
        };
        if showing(&target, false).is_some_and(|other| !Rc::ptr_eq(&other, self)) {
            let heading = format!("Couldn't save as “{}”", display_name(&target));
            self.alert(&heading, "It is open in another window.");
            return false;
        }
        let text = self.source_text();
        let edits = self.edits.get();
        let result = file::save(&target, &text, None).await;
        let saved = self.finish_save(&target, result, edits);
        if saved {
            self.file.replace(Some(target.clone()));
            self.unchecked.set(false);
            self.watch(&target);
            self.update_title();
            // Edits during the save need a copy under the new name.
            self.autosave();
        }
        saved
    }

    fn finish_save(&self, file: &gio::File, result: Result<Guard, SaveError>, edits: u64) -> bool {
        match result {
            Ok(guard) => {
                self.guard.replace(Some(guard));
                self.saves.set(self.saves.get() + 1);
                // Typing during the save leaves the document modified: that text isn't saved.
                if self.edits.get() == edits {
                    self.source.set_modified(false);
                }
                self.changed.revealer.set_reveal_child(false);
                // Saved: nothing recovered is left to keep or discard.
                self.recovered.revealer.set_reveal_child(false);
                self.update_title();
                true
            }
            // save() answers conflicts itself, and Save As writes without a guard.
            Err(SaveError::Conflict) => false,
            Err(SaveError::Failed { message, in_place }) => {
                let mut detail = sentence(&message);
                if in_place {
                    detail.push_str(
                        " It was being rewritten in place, so it may now be incomplete: use \
                         Save As to keep a safe copy.",
                    );
                }
                self.alert(&format!("Couldn't save “{}”", display_name(file)), &detail);
                false
            }
        }
    }

    async fn ask_overwrite(&self, file: &gio::File) -> bool {
        let message = format!("“{}” changed on disk", display_name(file));
        let detail = "Another program changed it since mdview last read or saved it. Overwrite \
                      it with your version, or cancel and use Save As to keep both.";
        self.confirm(&message, detail, "_Overwrite").await
    }

    async fn ask_replace(&self, file: &gio::File) -> bool {
        let message = format!("“{}” already exists", display_name(file));
        self.confirm(&message, "Replace it with this document?", "_Replace")
            .await
    }

    /// Cancel, the default, or `action`; true for `action`.
    async fn confirm(&self, message: &str, detail: &str, action: &str) -> bool {
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(message)
            .detail(detail)
            .buttons(["_Cancel", action])
            .cancel_button(0)
            .default_button(0)
            .build();
        matches!(dialog.choose_future(Some(&self.window)).await, Ok(1))
    }

    fn alert(&self, message: &str, detail: &str) {
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(message)
            .detail(detail)
            .build();
        dialog.show(Some(&self.window));
    }

    /// Watches the file for outside changes, replacing any earlier watch.
    fn watch(self: &Rc<Self>, file: &gio::File) {
        let monitor = file
            .monitor_file(gio::FileMonitorFlags::NONE, gio::Cancellable::NONE)
            .ok();
        if let Some(monitor) = &monitor {
            let weak = Rc::downgrade(self);
            monitor.connect_changed(move |_, _, _, event| {
                // A write ends with ChangesDoneHint; a save that renames a new copy into place
                // (as gio's and most editors' do) shows as Created.
                let done = matches!(
                    event,
                    gio::FileMonitorEvent::ChangesDoneHint | gio::FileMonitorEvent::Created
                );
                if let (true, Some(win)) = (done, weak.upgrade()) {
                    win.check_disk();
                }
            });
        }
        self.monitor.replace(monitor);
    }

    /// After an outside change: an unmodified document reloads, keeping its place; one with
    /// unsaved work gets the changed-on-disk bar. mdview's own saves, and changes that leave the
    /// bytes as they were, are recognised by the guard's hash and ignored.
    fn check_disk(self: &Rc<Self>) {
        if self.saving.get() {
            return;
        }
        let Some(file) = self.file.borrow().clone() else {
            return;
        };
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            // Gone, unreadable or no longer a regular file: a save will recreate it or say why
            // it can't.
            let Ok(Some(disk)) = file::read_checked(&file).await else {
                return;
            };
            let Some(win) = weak.upgrade() else {
                return;
            };
            let still_ours = win.file.borrow().as_ref().is_some_and(|f| f.equal(&file));
            let unchanged = win
                .guard
                .borrow()
                .as_ref()
                .is_some_and(|g| g.matches(&disk.bytes));
            if win.saving.get() || !still_ours || unchanged {
                return;
            }
            if win.source.is_modified() {
                win.show_changed(&file);
            } else {
                win.load(file, false);
            }
        });
    }

    fn show_changed(&self, file: &gio::File) {
        self.changed.label.set_text(&format!(
            "“{}” changed on disk. Reload it and lose your changes, or keep yours (saving will \
             ask before overwriting).",
            display_name(file)
        ));
        self.changed.revealer.set_reveal_child(true);
    }

    /// Arms the 5-second autosave timer, unless it is armed. A late fire after a close does
    /// nothing: the gate and the closed slot refuse it.
    fn arm_autosave(self: &Rc<Self>) {
        if recovery_dir().is_none() || self.timer_armed.replace(true) {
            return;
        }
        self.after(Duration::from_secs(5), |win| {
            win.timer_armed.set(false);
            win.autosave();
        });
    }

    /// The write gate: a copy of the unsaved work, written on the thread pool. One write at a
    /// time; one asked for meanwhile runs when it finishes.
    fn autosave(self: &Rc<Self>) {
        let Some(dir) = recovery_dir() else {
            return;
        };
        if !self.has_work() {
            return;
        }
        if self.writing.get().is_some() {
            self.write_wanted.set(true);
            return;
        }
        let uri = self.file.borrow().as_ref().map(|f| String::from(f.uri()));
        let guard = self.guard.borrow().clone();
        let text = self.source_text();
        // The attempts digit is stamped from the slot when the write lands (recovery::run).
        let Some(bytes) =
            recovery::encode(0, recovery::now(), uri.as_deref(), guard.as_ref(), &text)
        else {
            let reason = "only documents up to 8 MiB, with a path that fits, are autosaved";
            self.set_note(Some(("Too large to autosave", reason.to_owned())));
            return;
        };
        let Some(job) = recovery::begin(&self.slot, &dir, &self.uuid, bytes) else {
            return;
        };
        let n = job.n;
        self.writing.set(Some(n));
        let handle = gio::spawn_blocking(move || recovery::run(job));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = handle.await;
            let Some(win) = weak.upgrade() else {
                return;
            };
            win.writing.set(None);
            let failure = match result {
                Ok(Ok(true)) => {
                    win.set_note(None);
                    None
                }
                // Dropped by a delete or close: it says nothing about an earlier note.
                Ok(Ok(false)) => None,
                Ok(Err(e)) => Some(format!("the last copy couldn't be written: {e}")),
                Err(_) => Some("the last copy's write failed unexpectedly".to_owned()),
            };
            // Tried again in 5 seconds, so the copy catches up once the cause clears.
            if let Some(reason) = failure {
                win.set_note(Some(("Autosave failed", reason)));
                win.arm_autosave();
            }
            if win.write_wanted.replace(false) {
                win.autosave();
            }
        });
        self.after(Duration::from_secs(30), move |win| {
            if win.writing.get() == Some(n) {
                let reason = "the last copy has taken over 30 seconds to write";
                win.set_note(Some(("Autosave failed", reason.to_owned())));
            }
        });
    }

    /// Deletes this window's copy (delete rules 1 and 2). A final delete also closes the slot,
    /// so no write lands after it.
    fn drop_copy(&self, final_delete: bool) {
        let Some(dir) = recovery_dir() else {
            return;
        };
        match recovery::delete(&self.slot, &dir, &self.uuid, final_delete) {
            Ok(()) if !final_delete => self.set_note(None),
            Ok(()) => {}
            // It would come back at the next start.
            Err(e) => {
                let reason = format!("the recovery copy couldn't be deleted: {e}");
                self.set_note(Some(("Autosave failed", reason)));
            }
        }
    }

    fn set_note(&self, note: Option<(&'static str, String)>) {
        self.note.replace(note);
        self.update_status();
    }

    /// A window for a recovered copy: its text, modified, in edit mode, under the recovered
    /// bar. Its file isn't touched until the deferred check finds the path local.
    fn recover(app: &gtk::Application, recovered: recovery::Recovered) {
        let copy = recovered.copy;
        // As in show(): text a buffer didn't take whole must never be saved over the file. It
        // is tried in a spare buffer, before any window exists; one that fails joins failed/
        // and the failed-copies notice.
        let held = {
            let spare = gtk::TextBuffer::new(None);
            spare.set_text(&copy.text);
            usize::try_from(spare.char_count()).unwrap_or(0)
        };
        if held != copy.text.chars().count() {
            if let Some(dir) = recovery_dir()
                && recovery::move_to_failed(&dir, &recovered.uuid).is_ok()
            {
                FAILED.set(FAILED.get() + 1);
            }
            return;
        }
        let win = Self::build(app, recovered.uuid, copy.attempts);
        let file = copy.uri.as_deref().map(gio::File::for_uri);
        // Not undoable, so undo can't make the window look clean. The timer counts as armed
        // meanwhile, so putting the text back doesn't rewrite the copy with a new time.
        win.timer_armed.set(true);
        win.set_text_irreversibly(&copy.text);
        win.timer_armed.set(false);
        win.source.place_cursor(&win.source.start_iter());
        win.source.set_modified(true);
        win.unchecked.set(file.is_some());
        win.file.replace(file.clone());
        win.guard.replace(copy.guard.clone());
        win.has_doc.set(true);
        let when = autosaved_at(copy.time);
        let message = match &file {
            Some(file) => format!(
                "Recovered unsaved changes to “{}” (autosaved {when}). Keep them, or discard \
                 them and reload the file.",
                display_name(file)
            ),
            None => format!(
                "Recovered an unsaved new document (autosaved {when}). Keep it, or discard it \
                 and close this window."
            ),
        };
        win.recovered.label.set_text(&message);
        win.recovered.revealer.set_reveal_child(true);
        win.update_title();
        win.update_actions();
        win.window.present();
        win.set_editing(true);
        // Up for 10 seconds: the crash counter goes back to 0.
        win.after(Duration::from_secs(10), |win| {
            if let Some(dir) = recovery_dir() {
                recovery::reset_attempts(&win.slot, &dir, &win.uuid);
            }
        });
        if let Some(file) = file {
            win.check_recovered(file, copy.text, copy.guard);
        }
    }

    /// The deferred check, off the main thread: whether the recovered file's path is local,
    /// and what the file holds now against the copy and its guard.
    fn check_recovered(self: &Rc<Self>, file: gio::File, text: String, guard: Option<Guard>) {
        let (edits, saves) = (self.edits.get(), self.saves.get());
        // path() too, since for a gvfs URI it asks gvfsd over D-Bus.
        let target = file.clone();
        let handle = gio::spawn_blocking(move || read_if_local(target.path()));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            // A path that isn't local, or a check that never returns, leaves the bar as it was.
            let Ok(Some(disk)) = handle.await else {
                return;
            };
            let Some(win) = weak.upgrade() else {
                return;
            };
            let same = win.file.borrow().as_ref().is_some_and(|f| f.equal(&file));
            // A pending load's file is matched by URI in showing() whatever this finds.
            if same {
                win.unchecked.set(false);
                if win.monitor.borrow().is_none() {
                    win.watch(&file);
                }
            }
            // Still the copy's guard: no save or load since has set one from newer bytes.
            let guard_ours = same && win.saves.get() == saves && *win.guard.borrow() == guard;
            let unchanged = guard_ours && win.edits.get() == edits;
            let matches_guard = |bytes: &[u8]| guard.as_ref().is_some_and(|g| g.matches(bytes));
            let note = match disk {
                Disk::Bytes(bytes) if bytes == text.as_bytes() => {
                    // The copy adds nothing. The guard follows the disk, so a save doesn't
                    // report a change nobody made; untouched, it is an ordinary clean window
                    // (delete rule 1).
                    if guard_ours {
                        win.guard.replace(Some(Guard::of(&bytes)));
                    }
                    if unchanged {
                        win.source.set_modified(false);
                        win.recovered.revealer.set_reveal_child(false);
                    }
                    None
                }
                Disk::Bytes(bytes) if matches_guard(&bytes) => None,
                Disk::Missing if guard.is_none() => None,
                Disk::Bytes(_) => {
                    Some("It has changed on disk since; saving will ask before overwriting.")
                }
                Disk::Missing => Some("The file no longer exists; saving recreates it."),
                Disk::Unreadable => None,
            };
            let showing_bar = win.recovered.revealer.reveals_child();
            if let (Some(note), true, true) = (note, showing_bar, win.saves.get() == saves) {
                let text = format!("{} {note}", win.recovered.label.text());
                win.recovered.label.set_text(&text);
            }
        });
    }

    /// The recovered bar's Discard: reload the file without a second prompt, or close the
    /// window when the file is gone or it is a new document.
    fn discard_recovered(self: &Rc<Self>) {
        let file = self.file.borrow().clone();
        let Some(file) = file else {
            if self.saving.get() || self.asking.get() > 0 {
                self.not_discarded();
            } else {
                self.close_agreed();
            }
            return;
        };
        let (edits, saves) = (self.edits.get(), self.saves.get());
        let this_load = self.loads.get() + 1;
        self.loads.set(this_load);
        self.pending.replace(Some(file.clone()));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = file::load(&file).await;
            let Some(win) = weak.upgrade() else {
                return;
            };
            if win.loads.get() != this_load {
                return;
            }
            win.pending.replace(None);
            // Keep (or a save) since the click has hidden the bar: the user's later choice wins.
            if !win.recovered.revealer.reveals_child() {
                return;
            }
            // Typed or saved after the click, saving now, or asking whether to: that work isn't
            // thrown away, and the window isn't closed under its prompt.
            let busy = win.edits.get() != edits
                || win.saves.get() != saves
                || win.saving.get()
                || win.asking.get() > 0;
            match result {
                Err(LoadError::Failed(reason)) => win.alert(
                    &format!("Couldn't reload “{}”", display_name(&file)),
                    &sentence(&reason),
                ),
                _ if busy => win.not_discarded(),
                Err(LoadError::NotFound) => win.close_agreed(),
                Ok(loaded) => win.show(&file, loaded, false),
            }
        });
    }

    fn not_discarded(&self) {
        self.alert(
            "Not discarded",
            "The document changed, is being saved, or is waiting on a prompt, so it was kept. \
             Discard again once that is done.",
        );
    }

    /// Closes with the close already agreed, so there is no prompt.
    fn close_agreed(&self) {
        self.closing.set(true);
        self.window.close();
    }

    /// Switches between the rendered view and the source, keeping the place in the document.
    fn set_editing(self: &Rc<Self>, edit: bool) {
        if !self.has_doc.get() || edit == self.editing() {
            self.edit_action.set_state(&self.editing().to_variant());
            return;
        }
        let line = self.top_line();
        if edit {
            self.fit_editor_margins();
            self.stack.set_visible_child_name("edit");
            self.scroll_editor_to(line);
            self.editor.grab_focus();
        } else {
            self.show_view();
            self.scroll_view_to(line);
        }
        self.edit_action.set_state(&edit.to_variant());
        self.update_status();
        if self.bar.is_open() {
            self.run_find(true, true);
        }
    }

    /// Shows the rendered view, rebuilding it first if the source has changed.
    fn show_view(self: &Rc<Self>) {
        if self.stale.get() {
            let rendered = render::render(&self.source_text());
            let weak = Rc::downgrade(self);
            let on_link: Rc<dyn Fn(&str)> = Rc::new(move |href| {
                if let Some(win) = weak.upgrade() {
                    win.open_link(href);
                }
            });
            let theme = Theme::from(&self.probes);
            let layout = fill(&self.view, &rendered, &theme, &on_link);
            self.blocks.replace(rendered.blocks);
            self.links.replace(rendered.links);
            self.layout.replace(layout);
            self.relayout();
            self.stale.set(false);
        }
        self.stack.set_visible_child_name("view");
        self.edit_action.set_state(&false.to_variant());
        self.update_status();
    }

    /// The source line at the top of whichever view is showing.
    fn top_line(&self) -> usize {
        // By height alone: the top-left corner is in the margin, where there is no text.
        let view = self.active();
        let (at, _) = view.line_at_y(view.visible_rect().y());
        if self.editing() {
            return usize::try_from(at.line()).unwrap_or(0);
        }
        let offset = usize::try_from(at.offset()).unwrap_or(0);
        let blocks = self.blocks.borrow();
        let index = blocks.partition_point(|&(start, _)| start <= offset);
        index.checked_sub(1).map_or(0, |i| blocks[i].1)
    }

    fn scroll_editor_to(&self, line: usize) {
        let at = self
            .source
            .iter_at_line(offset(line))
            .unwrap_or_else(|| self.source.end_iter());
        self.source.place_cursor(&at);
        scroll_to_top(&self.editor, &at);
    }

    /// Scrolls the rendered view to the last block starting at or before `line`.
    fn scroll_view_to(&self, line: usize) {
        let start = self
            .blocks
            .borrow()
            .iter()
            .rev()
            .find(|&&(_, l)| l <= line)
            .map_or(0, |&(start, _)| start);
        let at = self.view.buffer().iter_at_offset(offset(start));
        scroll_to_top(&self.view, &at);
    }

    /// Sizes the editor's margins from its own font, once it is in the window.
    fn fit_editor_margins(&self) {
        let em = text_width(&self.editor, "M");
        self.editor.set_left_margin(2 * em);
        self.editor.set_right_margin(2 * em);
        self.editor.set_top_margin(em);
        self.editor.set_bottom_margin(4 * em);
    }

    fn open_bar(&self, mode: Mode) {
        // A short, single-line selection becomes the search.
        if mode != Mode::GoTo
            && let Some((start, end)) = self.active().buffer().selection_bounds()
        {
            let text = start.text(&end);
            if !text.contains('\n') && text.chars().count() <= 100 {
                self.bar.find.set_text(&text);
            }
        }
        self.bar.show(mode);
    }

    fn highlight(&self) -> find::Highlight {
        find::Highlight {
            background: self.probes.match_bg.color(),
            foreground: self.probes.match_fg.color(),
        }
    }

    fn close_bar(&self) {
        self.bar.hide();
        find::clear(&self.view);
        find::clear(&self.editor);
        self.active().grab_focus();
    }

    fn find_again(&self, forward: bool) {
        if self.bar.is_open() && !self.bar.find.text().is_empty() {
            self.run_find(forward, false);
        } else {
            self.open_bar(Mode::Find);
        }
    }

    fn run_find(&self, forward: bool, from_start: bool) {
        let needle = self.bar.find.text();
        if needle.is_empty() {
            self.bar.set_status("", false);
            return;
        }
        let case = self.bar.case.is_active();
        let found = find::find(
            self.active(),
            &needle,
            case,
            forward,
            from_start,
            &self.highlight(),
        );
        self.bar
            .set_status(if found { "" } else { "No match" }, !found);
    }

    /// Replace works on the source only, so it switches to editing first.
    fn replace(self: &Rc<Self>, all: bool) {
        self.set_editing(true);
        let needle = self.bar.find.text();
        let replacement = self.bar.replacement.text();
        let case = self.bar.case.is_active();
        if all {
            let count = find::replace_all(&self.editor, &needle, &replacement, case);
            let note = match count {
                0 => "No match".to_owned(),
                1 => "1 replaced".to_owned(),
                n => format!("{n} replaced"),
            };
            self.bar.set_status(&note, count == 0);
        } else {
            let colours = self.highlight();
            let more = find::replace(&self.editor, &needle, &replacement, case, &colours);
            self.bar
                .set_status(if more { "" } else { "No match" }, !more);
        }
    }

    /// Centres the reading column in the current width and moves every margin with it.
    fn relayout(&self) {
        let layout = self.layout.borrow();
        let width = self.scroller.hadjustment().page_size() as i32;
        // Zero until the window is first allocated; the page-size notify comes back then. With no
        // document laid out yet there is nothing to centre (and a zero measure would make the
        // margins half the width, pinning the window's minimum size).
        if width <= 0 || layout.measure == 0 || width == layout.width.get() {
            return;
        }
        layout.width.set(width);
        let margin = ((width - layout.measure) / 2).max(layout.min_margin);
        if let Some(column) = &layout.column {
            column.set_left_margin(margin);
            column.set_right_margin(margin);
        }
        for (tag, offset) in &layout.indents {
            // A long number's marker can hang out past a narrow margin; GTK's margin can't go
            // below zero (and glib panics on an out-of-range property).
            tag.set_left_margin((margin + offset).max(0));
        }
        // TextView gives an anchored widget its minimum size, and both are wrong for a table:
        // a horizontal scroller's minimum width is near zero, and the grid's minimum height is
        // measured at one character per column. So each table's minimum is set to its natural
        // width, capped at the room its line has, and to the height its cells wrap to at that
        // width. The cap is one indent step under the room: that minimum counts toward the
        // window's, so a drag can always narrow the window a step, and the next pass refits.
        // The minimums are cleared first, as GTK refuses a maximum below the current minimum.
        let column = width - 2 * margin;
        for (table, level) in &layout.tables {
            let Some(grid) = table.child() else {
                continue;
            };
            let room = (column - i32::from(*level) * layout.step - layout.step).max(1);
            // The grid itself is never narrower than its own minimum: past that it scrolls.
            let (minimum, natural, ..) = grid.measure(gtk::Orientation::Horizontal, -1);
            let fit = natural.min(room);
            let mut height = grid.measure(gtk::Orientation::Vertical, fit.max(minimum)).1;
            if minimum > fit && !table.is_overlay_scrolling() {
                // A classic scrollbar takes its own height from the scroller.
                height += table.hscrollbar().measure(gtk::Orientation::Vertical, -1).1;
            }
            table.set_min_content_width(-1);
            table.set_max_content_width(room);
            table.set_min_content_width(fit);
            table.set_min_content_height(height);
        }
    }
}

/// Marks a save as running for as long as it lives, so a second can't start meanwhile.
struct Busy<'a>(&'a Cell<bool>);

impl<'a> Busy<'a> {
    fn start(flag: &'a Cell<bool>) -> Option<Self> {
        (!flag.replace(true)).then_some(Self(flag))
    }
}

impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

impl Status {
    fn new() -> Self {
        let folder = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::Start)
            .build();
        let details = gtk::Label::new(None);
        let note = gtk::Label::new(None);
        note.set_visible(false);
        for label in [&folder, &details, &note] {
            label.add_css_class("md-status-text");
        }
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        bar.add_css_class("md-status");
        bar.append(&folder);
        bar.append(&details);
        bar.append(&note);
        bar.set_visible(false);
        Self {
            bar,
            folder,
            details,
            note,
        }
    }
}

impl InfoBar {
    fn new(act: &str, keep: &str) -> Self {
        let label = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .hexpand(true)
            .build();
        let act = gtk::Button::with_label(act);
        let keep = gtk::Button::with_label(keep);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.add_css_class("md-bar");
        row.append(&label);
        row.append(&act);
        row.append(&keep);
        let revealer = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideDown)
            .child(&row)
            .build();
        Self {
            revealer,
            label,
            act,
            keep,
        }
    }
}

fn header_bar() -> gtk::HeaderBar {
    let open = gtk::Button::from_icon_name("document-open-symbolic");
    open.set_tooltip_text(Some("Open a Markdown file (Ctrl+O)"));
    open.set_action_name(Some("win.open"));
    let save = gtk::Button::from_icon_name("document-save-symbolic");
    save.set_tooltip_text(Some("Save (Ctrl+S)"));
    save.set_action_name(Some("win.save"));
    let edit = gtk::ToggleButton::builder()
        .icon_name("document-edit-symbolic")
        .tooltip_text("Edit the source (Ctrl+E)")
        .action_name("win.edit")
        .build();
    let menu = gtk::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .tooltip_text("Menu")
        .menu_model(&main_menu())
        .build();
    let header = gtk::HeaderBar::new();
    header.pack_start(&open);
    header.pack_end(&menu);
    header.pack_end(&edit);
    header.pack_end(&save);
    header
}

fn main_menu() -> gio::Menu {
    let section = |items: &[(&str, &str)]| {
        let section = gio::Menu::new();
        for (label, action) in items {
            section.append(Some(label), Some(action));
        }
        section
    };
    let menu = gio::Menu::new();
    menu.append_section(
        None,
        &section(&[
            ("New", "win.new"),
            ("Open…", "win.open"),
            ("Save As…", "win.save-as"),
        ]),
    );
    menu.append_section(
        None,
        &section(&[
            ("Find…", "win.find"),
            ("Replace…", "win.replace"),
            ("Go to Line…", "win.goto"),
            ("Word Wrap", "win.wrap"),
        ]),
    );
    menu.append_section(None, &section(&[("Quit", "app.quit")]));
    menu
}

async fn exists(file: &gio::File) -> bool {
    file.query_info_future(
        "standard::type",
        gio::FileQueryInfoFlags::NONE,
        glib::Priority::DEFAULT,
    )
    .await
    .is_ok()
}

fn scrolled(view: &gtk::TextView) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(view)
        .build()
}

/// Scrolls `view` so `at` is at the top, through a mark: unlike an iterator, a mark is still
/// right after the view's next layout, which a switch between views needs.
fn scroll_to_top(view: &gtk::TextView, at: &gtk::TextIter) {
    let buffer = view.buffer();
    let mark = match buffer.mark("mdview-top") {
        Some(mark) => {
            buffer.move_mark(&mark, at);
            mark
        }
        None => buffer.create_mark(Some("mdview-top"), at, true),
    };
    view.scroll_to_mark(&mark, 0.0, true, 0.0, 0.0);
}

/// The tag colours, read from the probes when a document is shown.
struct Theme {
    link: gdk::RGBA,
    dim: gdk::RGBA,
    tint: gdk::RGBA,
}

impl From<&Probes> for Theme {
    fn from(p: &Probes) -> Self {
        Self {
            link: p.link.color(),
            dim: p.dim.color(),
            tint: p.tint.color(),
        }
    }
}

/// Builds a fresh buffer for the view from the rendered document.
fn fill(view: &gtk::TextView, r: &Rendered, theme: &Theme, on_link: &Rc<dyn Fn(&str)>) -> Layout {
    let buffer = gtk::TextBuffer::new(None);
    buffer.set_text(&r.text);
    let em = text_width(view, "M");
    view.set_top_margin(2 * em);
    view.set_bottom_margin(4 * em);
    let mut layout = Layout {
        measure: text_width(view, &"n".repeat(80)),
        min_margin: text_width(view, "00"),
        step: text_width(view, "0000"),
        width: Cell::new(-1),
        ..Layout::default()
    };

    // Each table's placeholder becomes its anchor before any tag goes on, so the offsets stay
    // true and the tags around a table cover it. Last first, for the same reason.
    let mut anchors = Vec::new();
    for anchor in r.tables.iter().rev() {
        let mut at = buffer.iter_at_offset(offset(anchor.offset));
        // forward_char reports false on reaching the end, so its result isn't the test: a table
        // that ends the document has its placeholder as the last character.
        if at.char() == ANCHOR {
            let mut next = at;
            next.forward_char();
            buffer.delete(&mut at, &mut next);
        }
        anchors.push((buffer.create_child_anchor(&mut at), anchor));
    }

    // The column tag first, so it has the lowest priority; then the rest in Style order, so a
    // deeper indent outranks the shallower one it sits in (render::Style).
    let column = gtk::TextTag::new(None);
    buffer.tag_table().add(&column);
    buffer.apply_tag(&column, &buffer.start_iter(), &buffer.end_iter());
    layout.column = Some(column);
    let mut styles: Vec<Style> = r.spans.iter().map(|s| s.style).collect();
    styles.sort();
    styles.dedup();
    let tags: BTreeMap<Style, gtk::TextTag> = styles
        .into_iter()
        .map(|style| {
            let tag = make_tag(style, theme, view, &mut layout);
            buffer.tag_table().add(&tag);
            (style, tag)
        })
        .collect();
    for span in &r.spans {
        let start = buffer.iter_at_offset(offset(span.start));
        let end = buffer.iter_at_offset(offset(span.end));
        buffer.apply_tag(&tags[&span.style], &start, &end);
    }

    view.set_buffer(Some(&buffer));
    for (child, anchor) in anchors {
        let table = table_widget(&anchor.table, on_link);
        view.add_child_at_anchor(&table, &child);
        layout.tables.push((table, anchor.level));
    }
    layout
}

fn make_tag(
    style: Style,
    theme: &Theme,
    view: &gtk::TextView,
    layout: &mut Layout,
) -> gtk::TextTag {
    let tag = gtk::TextTag::new(None);
    match style {
        Style::Heading(level) => {
            tag.set_weight(700);
            tag.set_scale([1.8, 1.5, 1.25, 1.1, 1.0, 0.9][usize::from(level.clamp(1, 6) - 1)]);
            if level == 6 {
                tag.set_foreground_rgba(Some(&theme.dim));
            }
        }
        Style::Emphasis => tag.set_style(pango::Style::Italic),
        Style::Strong => tag.set_weight(700),
        Style::Strike => tag.set_strikethrough(true),
        Style::Code => {
            tag.set_family(Some("monospace"));
            tag.set_background_rgba(Some(&theme.tint));
        }
        Style::CodeBlock => {
            tag.set_family(Some("monospace"));
            tag.set_paragraph_background_rgba(Some(&theme.tint));
        }
        Style::FrontMatter => {
            tag.set_family(Some("monospace"));
            tag.set_paragraph_background_rgba(Some(&theme.tint));
            tag.set_foreground_rgba(Some(&theme.dim));
        }
        Style::Html => {
            tag.set_family(Some("monospace"));
            tag.set_foreground_rgba(Some(&theme.dim));
        }
        Style::Link => {
            tag.set_underline(pango::Underline::Single);
            tag.set_foreground_rgba(Some(&theme.link));
        }
        Style::ImageAlt => {
            tag.set_style(pango::Style::Italic);
            tag.set_foreground_rgba(Some(&theme.dim));
        }
        Style::Quote => tag.set_foreground_rgba(Some(&theme.dim)),
        Style::Rule => {
            tag.set_justification(gtk::Justification::Center);
            tag.set_foreground_rgba(Some(&theme.dim));
        }
        Style::Indent { level } => {
            layout
                .indents
                .push((tag.clone(), i32::from(level) * layout.step));
        }
        Style::Hang { marker, level } => {
            // Pango hangs a negative indent the other way round: the first line sits at the
            // margin and the rest move right. So the marker's paragraph starts a marker's width
            // left of the text, and its wrapped lines land on the text.
            let text = match marker {
                Marker::Bullet(i) => BULLETS[usize::from(i) % BULLETS.len()].to_owned(),
                Marker::Task => TASK_BOXES[0].to_owned(),
                Marker::Number { digits } => format!("{}. ", "0".repeat(usize::from(digits))),
            };
            let hang = text_width(view, &text);
            tag.set_indent(-hang);
            layout
                .indents
                .push((tag.clone(), i32::from(level) * layout.step - hang));
        }
    }
    tag
}

fn table_widget(table: &render::Table, on_link: &Rc<dyn Fn(&str)>) -> gtk::ScrolledWindow {
    let grid = gtk::Grid::new();
    grid.add_css_class("md-table");
    for (row, cells) in table.rows.iter().enumerate() {
        for (column, markup) in cells.iter().enumerate() {
            let label = gtk::Label::new(None);
            label.set_markup(markup);
            // Words only: a table that can't fit even then scrolls sideways rather than breaking
            // every cell into single characters.
            label.set_wrap(true);
            label.set_wrap_mode(pango::WrapMode::Word);
            label.set_max_width_chars(40);
            label.set_selectable(true);
            label.add_css_class("md-cell");
            if row == 0 {
                label.add_css_class("md-th");
            }
            let (xalign, justify) = match table.align.get(column) {
                Some(pulldown_cmark::Alignment::Center) => (0.5, gtk::Justification::Center),
                Some(pulldown_cmark::Alignment::Right) => (1.0, gtk::Justification::Right),
                _ => (0.0, gtk::Justification::Left),
            };
            label.set_xalign(xalign);
            label.set_justify(justify);
            // Never let GTK launch a link itself: it goes through the same check as the text's.
            let on_link = on_link.clone();
            label.connect_activate_link(move |_, href| {
                on_link(href);
                glib::Propagation::Stop
            });
            let (x, y) = (offset(column), offset(row));
            grid.attach(&label, x, y, 1, 1);
        }
    }
    // Its own horizontal scroller, so a table too wide even after wrapping scrolls instead of
    // widening the window. Vertically it never scrolls: relayout sets its height (External).
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::External)
        .child(&grid)
        .build()
}

fn empty_page() -> gtk::Box {
    let title = gtk::Label::new(Some("No document open"));
    title.add_css_class("md-empty-title");
    let hint = gtk::Label::new(Some(
        "Open a Markdown file with Ctrl+O, start one with Ctrl+N, or drop one here.",
    ));
    hint.add_css_class("md-empty-hint");
    let page = gtk::Box::new(gtk::Orientation::Vertical, 6);
    page.set_valign(gtk::Align::Center);
    page.set_halign(gtk::Align::Center);
    page.append(&title);
    page.append(&hint);
    page
}

fn probe_label(class: &str) -> gtk::Label {
    let label = gtk::Label::new(None);
    label.add_css_class(class);
    label
}

/// Pixel width of `s` in the view's font, so spacing follows the GTK font size.
fn text_width(view: &gtk::TextView, s: &str) -> i32 {
    view.create_pango_layout(Some(s)).pixel_size().0
}

/// A reason ("it isn't a regular file") as a sentence: capitalised, with a full stop.
fn sentence(reason: &str) -> String {
    let mut chars = reason.chars();
    let first = chars.next().map(|c| c.to_uppercase().collect::<String>());
    let end = if reason.ends_with('.') { "" } else { "." };
    format!("{}{}{end}", first.unwrap_or_default(), chars.as_str())
}

/// Whether two files are the same one, through symlinks and `..` as well (`File::equal` only
/// compares URIs). Resolving a local path is a quick stat.
fn same_file(a: &gio::File, b: &gio::File) -> bool {
    let real = |f: &gio::File| f.path().and_then(|p| std::fs::canonicalize(p).ok());
    a.equal(b) || real(a).is_some_and(|ra| real(b).is_some_and(|rb| ra == rb))
}

/// A folder for the status line, with the home folder shown as `~`.
fn home_relative(folder: &gio::File) -> String {
    let Some(path) = folder.path() else {
        return folder.uri().into();
    };
    match path.strip_prefix(glib::home_dir()) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".to_owned(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

/// What a recovered file holds now, read off the main thread.
enum Disk {
    Bytes(Vec<u8>),
    Missing,
    Unreadable,
}

/// `None` when the path isn't local (recovery::is_local_path), so it was never touched.
fn read_if_local(path: Option<PathBuf>) -> Option<Disk> {
    use std::io::Read;
    let path = path?;
    if !recovery::is_local_path(&path) {
        return None;
    }
    let limit = file::MAX_BYTES.unsigned_abs();
    Some(match std::fs::metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Disk::Missing,
        // Capped, in case it grew since the check.
        Ok(meta) if meta.is_file() && meta.len() <= limit => {
            let mut bytes = Vec::new();
            let read =
                std::fs::File::open(&path).and_then(|f| f.take(limit + 1).read_to_end(&mut bytes));
            match read {
                Ok(_) if bytes.len() as u64 <= limit => Disk::Bytes(bytes),
                _ => Disk::Unreadable,
            }
        }
        _ => Disk::Unreadable,
    })
}

/// A copy's time for the recovered bar: the time today, else the date too.
fn autosaved_at(time: i64) -> String {
    let (Ok(at), Ok(now)) = (
        glib::DateTime::from_unix_local(time),
        glib::DateTime::now_local(),
    ) else {
        return "at an unknown time".to_owned();
    };
    let pattern = if at.ymd() == now.ymd() {
        "%H:%M"
    } else if at.year() == now.year() {
        "%-d %b, %H:%M"
    } else {
        "%-d %b %Y, %H:%M"
    };
    at.format(pattern).map(String::from).unwrap_or_default()
}

fn display_name(file: &gio::File) -> String {
    file.basename()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.uri().into())
}

/// A character offset, line or grid index as GTK's `i32`. Files are capped at 8 MiB, so it fits.
fn offset(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}
