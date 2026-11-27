//! One window per document: the header bar, the rendered view, opening files and refusals.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{gdk, gio, glib, pango};

use crate::file;
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
    let empty = WINDOWS.with_borrow(|ws| {
        ws.iter()
            .find(|w| w.file.borrow().is_none() && w.pending.borrow().is_none())
            .cloned()
    });
    let win = empty.unwrap_or_else(|| Win::new(app));
    win.window.present();
    win.load(file);
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
    view: gtk::TextView,
    probes: Probes,
    file: RefCell<Option<gio::File>>,
    /// The file being loaded, and a count of loads started: only the latest load's result is
    /// shown, so a slow load can't replace a newer one.
    pending: RefCell<Option<gio::File>>,
    loads: Cell<u64>,
    layout: RefCell<Layout>,
}

/// Hidden widgets whose computed colours become the tag colours: tags take colour values, not
/// CSS, and this way the colours still come from the theme. `style.css` styles the labels;
/// the link button carries the theme's own link colour (Nordic has no named one).
struct Probes {
    link: gtk::LinkButton,
    dim: gtk::Label,
    tint: gtk::Label,
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
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&view)
            .build();

        let stack = gtk::Stack::new();
        stack.add_named(&empty_page(), Some("empty"));
        stack.add_named(&scroller, Some("view"));

        let probes = Probes {
            link: gtk::LinkButton::new("about:blank"),
            dim: probe_label("md-probe-dim"),
            tint: probe_label("md-probe-tint"),
        };
        let probe_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        probe_box.append(&probes.link);
        probe_box.append(&probes.dim);
        probe_box.append(&probes.tint);
        probe_box.set_visible(false);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&stack);
        content.append(&probe_box);

        let open_button = gtk::Button::from_icon_name("document-open-symbolic");
        open_button.set_tooltip_text(Some("Open a Markdown file (Ctrl+O)"));
        open_button.set_action_name(Some("win.open"));
        let header = gtk::HeaderBar::new();
        header.pack_start(&open_button);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("mdview")
            .default_width(900)
            .default_height(1000)
            .titlebar(&header)
            .child(&content)
            .build();

        let win = Rc::new(Self {
            window,
            stack,
            scroller,
            view,
            probes,
            file: RefCell::new(None),
            pending: RefCell::new(None),
            loads: Cell::new(0),
            layout: RefCell::new(Layout::default()),
        });
        win.connect();
        WINDOWS.with_borrow_mut(|ws| ws.push(win.clone()));
        win
    }

    /// Actions, the file drop and the resize hook. Closures hold the window weakly: it owns them.
    fn connect(self: &Rc<Self>) {
        let open_action = gio::SimpleAction::new("open", None);
        let weak = Rc::downgrade(self);
        open_action.connect_activate(move |_, _| {
            if let Some(win) = weak.upgrade() {
                win.choose_file();
            }
        });
        self.window.add_action(&open_action);

        let close = gio::SimpleAction::new("close", None);
        let window = self.window.downgrade();
        close.connect_activate(move |_, _| {
            if let Some(window) = window.upgrade() {
                window.close();
            }
        });
        self.window.add_action(&close);

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

        self.window.connect_close_request(|window| {
            WINDOWS.with_borrow_mut(|ws| ws.retain(|w| &w.window != window));
            glib::Propagation::Proceed
        });
    }

    fn choose_file(self: &Rc<Self>) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Markdown"));
        // Suffixes match without regard to case.
        filter.add_suffix("md");
        filter.add_suffix("markdown");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title("Open Markdown file")
            .modal(true)
            .filters(&filters)
            .default_filter(&filter)
            .build();
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

    /// Opens a file in this window, unless another window already shows it.
    fn open_here(self: &Rc<Self>, file: gio::File) {
        match showing(&file) {
            Some(other) if !Rc::ptr_eq(&other, self) => other.window.present(),
            _ => self.load(file),
        }
    }

    /// Loads, validates, then swaps: a file that fails to load never replaces the current one.
    fn load(self: &Rc<Self>, file: gio::File) {
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
            win.pending.replace(None);
            match result {
                Ok(text) => win.show(&file, &text),
                Err(reason) => win.refuse(&file, &reason),
            }
        });
    }

    fn show(&self, file: &gio::File, text: &str) {
        let rendered = render::render(text);
        let layout = fill(&self.view, &rendered, &Theme::from(&self.probes));
        self.layout.replace(layout);
        self.relayout();
        self.window.set_title(Some(&display_name(file)));
        self.file.replace(Some(file.clone()));
        self.stack.set_visible_child_name("view");
        self.scroller.vadjustment().set_value(0.0);
    }

    fn refuse(&self, file: &gio::File, reason: &str) {
        let dialog = gtk::AlertDialog::builder()
            .modal(true)
            .message(format!("Couldn't open “{}”", display_name(file)))
            .detail(sentence(reason))
            .build();
        dialog.show(Some(&self.window));
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
fn fill(view: &gtk::TextView, r: &Rendered, theme: &Theme) -> Layout {
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
        let table = table_widget(&anchor.table);
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

fn table_widget(table: &render::Table) -> gtk::ScrolledWindow {
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
            // Never let GTK launch a link itself; Phase 3 handles links.
            label.connect_activate_link(|_, _| glib::Propagation::Stop);
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
    let hint = gtk::Label::new(Some("Open a Markdown file with Ctrl+O, or drop one here."));
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

/// A refusal reason ("it isn't a regular file") as a sentence: capitalised, with a full stop.
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

fn display_name(file: &gio::File) -> String {
    file.basename()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.uri().into())
}

/// A character offset or grid index as GTK's `i32`. Files are capped at 8 MiB, so it fits.
fn offset(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}
