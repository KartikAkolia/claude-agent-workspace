//! One window per document: the rendered view and the source editor, opening and saving, the
//! unsaved-work prompts, and watching the file for outside changes.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{gdk, gio, glib, pango};

use crate::file::{self, Guard, Loaded, SaveError};
use crate::find::{self, Bar, Mode};
use crate::link::{self, Target};
use crate::render::{self, ANCHOR, BULLETS, Marker, Rendered, Style, TASK_BOXES};

thread_local! {
    /// Every open window, so a file that is already open is focused rather than opened twice.
    static WINDOWS: RefCell<Vec<Rc<Win>>> = const { RefCell::new(Vec::new()) };
}

/// Presents a window: the first one open, or a new, empty one.
pub fn activate(app: &gtk::Application) {
    let first = WINDOWS.with_borrow(|ws| ws.first().cloned());
    first.unwrap_or_else(|| Win::new(app)).window.present();
}

/// Opens a file from the command line or the desktop: in the window already showing it, else in
/// an empty window, else in a new one.
pub fn open(app: &gtk::Application, file: gio::File) {
    if let Some(win) = showing(&file) {
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
                return;
            }
        }
        WINDOWS.with_borrow(|ws| ws.iter().for_each(|w| w.closing.set(true)));
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
fn showing(file: &gio::File) -> Option<Rc<Win>> {
    let is = |f: &Option<gio::File>| f.as_ref().is_some_and(|f| same_file(f, file));
    WINDOWS.with_borrow(|ws| {
        ws.iter()
            .find(|w| is(&w.file.borrow()) || is(&w.pending.borrow()))
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
    changed: Changed,
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
    /// `edits` when the user last chose Discard, so quit doesn't ask twice about the same text.
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
}

/// The status line under the text: the file's folder, then whether it is modified, the line
/// and column while editing, and the word count.
struct Status {
    bar: gtk::Box,
    folder: gtk::Label,
    details: gtk::Label,
}

/// The bar shown when the file changes on disk while there is unsaved work.
struct Changed {
    revealer: gtk::Revealer,
    label: gtk::Label,
    reload: gtk::Button,
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
        let changed = Changed::new();
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&bar.revealer);
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
        });
        win.connect_actions();
        win.connect_editor();
        win.connect_bars();
        win.connect_window();
        win.update_actions();
        WINDOWS.with_borrow_mut(|ws| ws.push(win.clone()));
        win
    }

    /// Unsaved work the user hasn't already agreed to discard.
    fn unsaved(&self) -> bool {
        self.has_doc.get()
            && self.source.is_modified()
            && self.discarded.get() != Some(self.edits.get())
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

    fn connect_editor(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.source.connect_changed(move |_| {
            if let Some(win) = weak.upgrade() {
                win.edits.set(win.edits.get() + 1);
                win.stale.set(true);
                win.count_words_soon();
            }
        });
        let weak = Rc::downgrade(self);
        self.source.connect_cursor_position_notify(move |_| {
            if let Some(win) = weak.upgrade() {
                win.update_status();
            }
        });
        let weak = Rc::downgrade(self);
        self.source.connect_modified_changed(move |_| {
            if let Some(win) = weak.upgrade() {
                win.update_title();
            }
        });

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
        let weak = Rc::downgrade(self);
        bar.find.connect_search_changed(move |_| {
            if let Some(win) = weak.upgrade() {
                win.run_find(true, true);
            }
        });
        for (forward, button) in [(true, &bar.next), (false, &bar.previous)] {
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(win) = weak.upgrade() {
                    win.run_find(forward, false);
                }
            });
        }
        let weak = Rc::downgrade(self);
        bar.find.connect_activate(move |_| {
            if let Some(win) = weak.upgrade() {
                win.run_find(true, false);
            }
        });
        let weak = Rc::downgrade(self);
        bar.find.connect_next_match(move |_| {
            if let Some(win) = weak.upgrade() {
                win.run_find(true, false);
            }
        });
        let weak = Rc::downgrade(self);
        bar.find.connect_previous_match(move |_| {
            if let Some(win) = weak.upgrade() {
                win.run_find(false, false);
            }
        });
        let weak = Rc::downgrade(self);
        bar.case.connect_toggled(move |_| {
            if let Some(win) = weak.upgrade() {
                win.run_find(true, true);
            }
        });
        let weak = Rc::downgrade(self);
        bar.find.connect_stop_search(move |_| {
            if let Some(win) = weak.upgrade() {
                win.close_bar();
            }
        });
        let weak = Rc::downgrade(self);
        bar.close.connect_clicked(move |_| {
            if let Some(win) = weak.upgrade() {
                win.close_bar();
            }
        });

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

        let weak = Rc::downgrade(self);
        bar.replace.connect_clicked(move |_| {
            if let Some(win) = weak.upgrade() {
                win.replace(false);
            }
        });
        let weak = Rc::downgrade(self);
        bar.replace_all.connect_clicked(move |_| {
            if let Some(win) = weak.upgrade() {
                win.replace(true);
            }
        });
        let weak = Rc::downgrade(self);
        bar.replacement.connect_activate(move |_| {
            if let Some(win) = weak.upgrade() {
                win.replace(false);
            }
        });
        let weak = Rc::downgrade(self);
        bar.line.connect_activate(move |entry| {
            let Some(win) = weak.upgrade() else {
                return;
            };
            match entry.text().trim().parse::<i32>() {
                Ok(line) => {
                    win.set_editing(true);
                    find::go_to_line(&win.editor, line);
                    win.close_bar();
                }
                Err(_) => win.bar.line_error(true),
            }
        });

        let weak = Rc::downgrade(self);
        self.changed.reload.connect_clicked(move |_| {
            let Some(win) = weak.upgrade() else {
                return;
            };
            win.changed.revealer.set_reveal_child(false);
            let file = win.file.borrow().clone();
            if let Some(file) = file {
                win.load(file, false);
            }
        });
        let weak = Rc::downgrade(self);
        self.changed.keep.connect_clicked(move |_| {
            if let Some(win) = weak.upgrade() {
                win.changed.revealer.set_reveal_child(false);
            }
        });
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
            win.open_here(first);
            if let Some(app) = win.window.application() {
                files.for_each(|file| open(&app, file));
            }
            true
        });
        self.window.add_controller(drop);

        // GTK4 has no resize signal; the scroller's horizontal page size is its width.
        let weak = Rc::downgrade(self);
        self.scroller
            .hadjustment()
            .connect_page_size_notify(move |_| {
                if let Some(win) = weak.upgrade() {
                    win.relayout();
                }
            });

        // Unsaved work holds the close until the prompt is answered.
        let weak = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            let Some(win) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if win.closing.get() || !win.has_doc.get() || !win.source.is_modified() {
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
        markdown_filter(&dialog);
        if let Some(folder) = self.file.borrow().as_ref().and_then(|f| f.parent()) {
            dialog.set_initial_folder(Some(&folder));
        }
        let weak = Rc::downgrade(self);
        let window = self.window.clone();
        glib::spawn_future_local(async move {
            // Cancelling the dialog is an error too; there is nothing to report for it.
            let Ok(file) = dialog.open_future(Some(&window)).await else {
                return;
            };
            if let Some(win) = weak.upgrade() {
                win.open_here(file);
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
            .and_then(|f| f.path());
        match link::resolve(href, folder.as_deref()) {
            Target::Markdown(path) => {
                let target = gio::File::for_path(path);
                // A link to this same document (`README.md#usage` inside README.md) is an
                // in-page jump, which does nothing, as `#usage` alone does.
                let here = self
                    .file
                    .borrow()
                    .as_ref()
                    .is_some_and(|f| same_file(f, &target));
                if !here {
                    self.open_here(target);
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
    fn open_here(self: &Rc<Self>, file: gio::File) {
        match showing(&file) {
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
                        &sentence(&reason),
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
        // Not undoable: undo never reaches back into the previous document.
        self.source.begin_irreversible_action();
        self.source.set_text(&loaded.text);
        self.source.end_irreversible_action();
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

    /// Back to an empty window, after a document that couldn't be held.
    fn close_document(&self) {
        self.file.replace(None);
        self.guard.replace(None);
        self.monitor.replace(None);
        self.has_doc.set(false);
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
        win.source.begin_irreversible_action();
        win.source.set_text("");
        win.source.end_irreversible_action();
        win.source.set_modified(false);
        win.file.replace(None);
        win.guard.replace(None);
        win.monitor.replace(None);
        win.has_doc.set(true);
        win.update_title();
        win.update_actions();
        win.fit_editor_margins();
        win.stack.set_visible_child_name("edit");
        win.edit_action.set_state(&true.to_variant());
        win.editor.grab_focus();
        win.update_status();
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
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(300), move || {
            let Some(win) = weak.upgrade() else {
                return;
            };
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
        self.status.bar.set_visible(self.has_doc.get());
        let folder = self
            .file
            .borrow()
            .as_ref()
            .and_then(|f| f.parent())
            .map_or_else(|| "Not saved yet".to_owned(), |f| home_relative(&f));
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

    fn name(&self) -> String {
        self.file
            .borrow()
            .as_ref()
            .map_or_else(|| "Untitled".to_owned(), display_name)
    }

    /// Asks before unsaved work is lost: Save, Discard or Cancel. True to go ahead (saved or
    /// discarded), false to stay.
    async fn confirm_discard(self: &Rc<Self>) -> bool {
        if !self.has_doc.get() || !self.source.is_modified() {
            return true;
        }
        self.window.present();
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(format!("Save changes to “{}”?", self.name()))
            .detail("Unsaved changes will be lost if you don't save them.")
            .buttons(["_Cancel", "_Discard", "_Save"])
            .cancel_button(0)
            .default_button(2)
            .build();
        match dialog.choose_future(Some(&self.window)).await {
            Ok(1) => {
                self.discarded.set(Some(self.edits.get()));
                true
            }
            Ok(2) => self.save().await,
            _ => false,
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
        loop {
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
                            return self.finish_save(&file, Err(failed), edits);
                        }
                    };
                }
                result => return self.finish_save(&file, result, edits),
            }
        }
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
        markdown_filter(&dialog);
        if let Some(folder) = current.as_ref().and_then(|f| f.parent()) {
            dialog.set_initial_folder(Some(&folder));
        }
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
        if showing(&target).is_some_and(|other| !Rc::ptr_eq(&other, self)) {
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
            self.watch(&target);
            self.update_title();
        }
        saved
    }

    fn finish_save(&self, file: &gio::File, result: Result<Guard, SaveError>, edits: u64) -> bool {
        match result {
            Ok(guard) => {
                self.guard.replace(Some(guard));
                // Typing during the save leaves the document modified: that text isn't saved.
                if self.edits.get() == edits {
                    self.source.set_modified(false);
                }
                self.changed.revealer.set_reveal_child(false);
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
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(format!("“{}” changed on disk", display_name(file)))
            .detail(
                "Another program changed it since mdview last read or saved it. Overwrite it \
                 with your version, or cancel and use Save As to keep both.",
            )
            .buttons(["_Cancel", "_Overwrite"])
            .cancel_button(0)
            .default_button(0)
            .build();
        matches!(dialog.choose_future(Some(&self.window)).await, Ok(1))
    }

    async fn ask_replace(&self, file: &gio::File) -> bool {
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(format!("“{}” already exists", display_name(file)))
            .detail("Replace it with this document?")
            .buttons(["_Cancel", "_Replace"])
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
        for label in [&folder, &details] {
            label.add_css_class("md-status-text");
        }
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        bar.add_css_class("md-status");
        bar.append(&folder);
        bar.append(&details);
        bar.set_visible(false);
        Self {
            bar,
            folder,
            details,
        }
    }
}

impl Changed {
    fn new() -> Self {
        let label = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .hexpand(true)
            .build();
        let reload = gtk::Button::with_label("Reload");
        let keep = gtk::Button::with_label("Keep Mine");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.add_css_class("md-bar");
        row.append(&label);
        row.append(&reload);
        row.append(&keep);
        let revealer = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideDown)
            .child(&row)
            .build();
        Self {
            revealer,
            label,
            reload,
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

fn markdown_filter(dialog: &gtk::FileDialog) {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some("Markdown"));
    // Suffixes match without regard to case.
    filter.add_suffix("md");
    filter.add_suffix("markdown");
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    dialog.set_filters(Some(&filters));
    dialog.set_default_filter(Some(&filter));
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

fn display_name(file: &gio::File) -> String {
    file.basename()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.uri().into())
}

/// A character offset, line or grid index as GTK's `i32`. Files are capped at 8 MiB, so it fits.
fn offset(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}
