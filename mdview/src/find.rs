//! The find, replace and go-to-line bar. Find works on whichever view is showing, the rendered
//! one or the source; replace and go to line work on the source.

use gtk::gdk;
use gtk::prelude::*;

/// The current match's colours: the theme's selection colours (window.rs reads them through
/// probe widgets). A tag, because a TextView only draws its selection while it has focus, and
/// during a search the focus is in the find field.
pub struct Highlight {
    pub background: gdk::RGBA,
    pub foreground: gdk::RGBA,
}

const MATCH_TAG: &str = "mdview-match";

/// Removes the match highlight from `view`.
pub fn clear(view: &gtk::TextView) {
    let buffer = view.buffer();
    if let Some(tag) = buffer.tag_table().lookup(MATCH_TAG) {
        buffer.remove_tag(&tag, &buffer.start_iter(), &buffer.end_iter());
    }
}

fn mark_match(
    view: &gtk::TextView,
    start: &gtk::TextIter,
    end: &gtk::TextIter,
    colours: &Highlight,
) {
    clear(view);
    let buffer = view.buffer();
    let table = buffer.tag_table();
    let tag = table.lookup(MATCH_TAG).unwrap_or_else(|| {
        let tag = gtk::TextTag::new(Some(MATCH_TAG));
        tag.set_background_rgba(Some(&colours.background));
        tag.set_foreground_rgba(Some(&colours.foreground));
        table.add(&tag);
        tag
    });
    // Above every other tag, links and code included.
    tag.set_priority(table.size() - 1);
    buffer.apply_tag(&tag, start, end);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Find,
    Replace,
    GoTo,
}

pub struct Bar {
    pub revealer: gtk::Revealer,
    pub find: gtk::SearchEntry,
    pub case: gtk::CheckButton,
    pub previous: gtk::Button,
    pub next: gtk::Button,
    pub close: gtk::Button,
    pub replacement: gtk::Entry,
    pub replace: gtk::Button,
    pub replace_all: gtk::Button,
    pub line: gtk::Entry,
    status: gtk::Label,
    find_row: gtk::Box,
    replace_row: gtk::Box,
    goto_row: gtk::Box,
}

impl Bar {
    pub fn new() -> Self {
        let find = gtk::SearchEntry::new();
        find.set_placeholder_text(Some("Find"));
        find.set_hexpand(true);
        let case = gtk::CheckButton::with_label("Match case");
        let previous = icon_button("go-up-symbolic", "Previous match (Shift+F3)");
        let next = icon_button("go-down-symbolic", "Next match (F3)");
        let status = gtk::Label::new(None);
        status.add_css_class("md-bar-status");
        let find_row = row(&[
            find.upcast_ref(),
            case.upcast_ref(),
            previous.upcast_ref(),
            next.upcast_ref(),
            status.upcast_ref(),
        ]);

        let replacement = gtk::Entry::builder()
            .placeholder_text("Replace with")
            .hexpand(true)
            .build();
        let replace = gtk::Button::with_label("Replace");
        let replace_all = gtk::Button::with_label("Replace All");
        let replace_row = row(&[
            replacement.upcast_ref(),
            replace.upcast_ref(),
            replace_all.upcast_ref(),
        ]);

        let line = gtk::Entry::builder()
            .placeholder_text("Line number")
            .input_purpose(gtk::InputPurpose::Digits)
            .build();
        let goto_row = row(&[
            gtk::Label::new(Some("Go to line")).upcast_ref(),
            line.upcast_ref(),
        ]);

        let rows = gtk::Box::new(gtk::Orientation::Vertical, 6);
        rows.set_hexpand(true);
        rows.append(&find_row);
        rows.append(&replace_row);
        rows.append(&goto_row);
        let close = icon_button("window-close-symbolic", "Close (Esc)");
        close.set_valign(gtk::Align::Start);
        let outer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        outer.add_css_class("md-bar");
        outer.append(&rows);
        outer.append(&close);
        let revealer = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideDown)
            .child(&outer)
            .build();

        Self {
            revealer,
            find,
            case,
            previous,
            next,
            close,
            replacement,
            replace,
            replace_all,
            line,
            status,
            find_row,
            replace_row,
            goto_row,
        }
    }

    pub fn show(&self, mode: Mode) {
        self.find_row.set_visible(mode != Mode::GoTo);
        self.replace_row.set_visible(mode == Mode::Replace);
        self.goto_row.set_visible(mode == Mode::GoTo);
        self.set_status("", false);
        self.line_error(false);
        self.revealer.set_reveal_child(true);
        if mode == Mode::GoTo {
            self.line.grab_focus();
        } else {
            self.find.grab_focus();
        }
    }

    /// Marks the line field with the theme's error style, for a line number that isn't one.
    pub fn line_error(&self, error: bool) {
        if error {
            self.line.add_css_class("error");
        } else {
            self.line.remove_css_class("error");
        }
    }

    pub fn hide(&self) {
        self.revealer.set_reveal_child(false);
    }

    pub fn is_open(&self) -> bool {
        self.revealer.reveals_child()
    }

    /// Shows a short note beside the find field; `error` also marks the field with the theme's
    /// own error style.
    pub fn set_status(&self, text: &str, error: bool) {
        self.status.set_text(text);
        if error {
            self.find.add_css_class("error");
        } else {
            self.find.remove_css_class("error");
        }
    }
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.set_tooltip_text(Some(tooltip));
    button
}

fn row(children: &[&gtk::Widget]) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    for child in children {
        row.append(*child);
    }
    row
}

fn flags(match_case: bool) -> gtk::TextSearchFlags {
    let flags = gtk::TextSearchFlags::TEXT_ONLY | gtk::TextSearchFlags::VISIBLE_ONLY;
    if match_case {
        flags
    } else {
        flags | gtk::TextSearchFlags::CASE_INSENSITIVE
    }
}

/// Selects the next (or previous) match of `needle` and scrolls to it, wrapping round at either
/// end; false when there is none. Forward, it searches from the selection's end, or from its
/// start with `from_start`, so typing more of the needle refines the current match rather than
/// skipping past it.
pub fn find(
    view: &gtk::TextView,
    needle: &str,
    match_case: bool,
    forward: bool,
    from_start: bool,
    colours: &Highlight,
) -> bool {
    if needle.is_empty() {
        clear(view);
        return true;
    }
    let buffer = view.buffer();
    let flags = flags(match_case);
    let (start, end) = buffer.selection_bounds().unwrap_or_else(|| {
        let at = buffer.iter_at_mark(&buffer.get_insert());
        (at, at)
    });
    let found = if forward {
        let from = if from_start { start } else { end };
        from.forward_search(needle, flags, None)
            .or_else(|| buffer.start_iter().forward_search(needle, flags, None))
    } else {
        start
            .backward_search(needle, flags, None)
            .or_else(|| buffer.end_iter().backward_search(needle, flags, None))
    };
    let Some((match_start, match_end)) = found else {
        clear(view);
        return false;
    };
    mark_match(view, &match_start, &match_end, colours);
    buffer.select_range(&match_start, &match_end);
    view.scroll_to_mark(&buffer.get_insert(), 0.1, false, 0.0, 0.0);
    true
}

/// Replaces the selection if it is a match, then moves on to the next match; false when there
/// is no next one.
pub fn replace(
    view: &gtk::TextView,
    needle: &str,
    replacement: &str,
    match_case: bool,
    colours: &Highlight,
) -> bool {
    if needle.is_empty() {
        return false;
    }
    let buffer = view.buffer();
    if let Some((mut start, mut end)) = buffer.selection_bounds() {
        let exact = start
            .forward_search(needle, flags(match_case), Some(&end))
            .is_some_and(|(s, e)| s == start && e == end);
        if exact {
            buffer.begin_user_action();
            buffer.delete(&mut start, &mut end);
            buffer.insert(&mut start, replacement);
            buffer.end_user_action();
            buffer.place_cursor(&start);
        }
    }
    find(view, needle, match_case, true, false, colours)
}

/// Replaces every match as one undo step and returns how many there were.
pub fn replace_all(
    view: &gtk::TextView,
    needle: &str,
    replacement: &str,
    match_case: bool,
) -> usize {
    if needle.is_empty() {
        return 0;
    }
    let buffer = view.buffer();
    let flags = flags(match_case);
    let mut count = 0;
    buffer.begin_user_action();
    let mut from = buffer.start_iter();
    while let Some((mut start, mut end)) = from.forward_search(needle, flags, None) {
        buffer.delete(&mut start, &mut end);
        buffer.insert(&mut start, replacement);
        // Carry on after the inserted text, so a replacement that contains the needle isn't
        // matched again.
        from = start;
        count += 1;
    }
    buffer.end_user_action();
    clear(view);
    count
}

/// Puts the cursor at the start of `line` (from 1, clamped to the document) and scrolls to it.
pub fn go_to_line(view: &gtk::TextView, line: i32) {
    let buffer = view.buffer();
    let line = line.clamp(1, buffer.line_count()) - 1;
    if let Some(at) = buffer.iter_at_line(line) {
        buffer.place_cursor(&at);
        view.scroll_to_mark(&buffer.get_insert(), 0.0, true, 0.0, 0.3);
    }
}
