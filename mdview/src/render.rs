//! Markdown to styled text. Pure Rust, no GTK, so all of it is unit-tested without a display;
//! `window.rs` turns the result into a `TextBuffer`.
//!
//! The output is the text to show, the styled ranges over it (in characters, which is what
//! `TextBuffer` offsets count) and the tables, which are drawn as widgets anchored in the text.
//! Each table has an `ANCHOR` character in the text where it goes, so the styles around it (a
//! quote's or a list item's indent) cover it.

use pulldown_cmark::{Alignment, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// CommonMark plus tables, task lists and strikethrough, and front matter so that a `---` block
/// isn't read as a rule and a heading. Nothing else (docs/mdview-plan.md, "Strictness").
const OPTIONS: Options = Options::ENABLE_TABLES
    .union(Options::ENABLE_TASKLISTS)
    .union(Options::ENABLE_STRIKETHROUGH)
    .union(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);

/// Drawn in place of a thematic break (`---`), centred.
pub const RULE: &str = "·  ·  ·";

/// Stands in for a table in `Rendered::text`; `window.rs` swaps it for the table's anchor.
pub const ANCHOR: char = '\u{FFFC}';

pub const BULLETS: [&str; 3] = ["• ", "◦ ", "▪ "];
pub const TASK_BOXES: [&str; 2] = ["☐ ", "☑ "];

/// A list item's marker, which sizes its hanging indent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Marker {
    /// An index into `BULLETS`.
    Bullet(u8),
    /// A task box, either of `TASK_BOXES`.
    Task,
    /// "1. " to "999999999. ": `digits` long, so "10. " hangs further than "9. ".
    Number { digits: u8 },
}

/// A text style. The derived order is the order tags are created in, and so their priority:
/// a deeper `Indent` sorts later and wins over the shallower one it sits inside.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Style {
    Heading(u8),
    Emphasis,
    Strong,
    Strike,
    Code,
    CodeBlock,
    FrontMatter,
    Html,
    Link,
    ImageAlt,
    Quote,
    Rule,
    /// Left indent for a list item or a quote, `level` counting both kinds of nesting.
    Indent {
        level: u8,
    },
    /// Covers just an item's marker. The marker's paragraph starts a marker's width left of the
    /// item's text, at `level`, so the marker hangs out and its wrapped lines line up with the
    /// text, as do the item's later paragraphs and code lines (which only have `Indent`).
    Hang {
        marker: Marker,
        level: u8,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub style: Style,
}

#[derive(Debug, PartialEq)]
pub struct Table {
    pub align: Vec<Alignment>,
    /// Row 0 is the header. Each cell is Pango markup, escaped here.
    pub rows: Vec<Vec<String>>,
}

#[derive(Debug, PartialEq)]
pub struct Anchor {
    /// Where the table goes: the offset of its `ANCHOR` in `Rendered::text`, in characters.
    pub offset: usize,
    /// The indent level it sits at, which narrows the width it has.
    pub level: u8,
    pub table: Table,
}

#[derive(Debug, Default, PartialEq)]
pub struct Rendered {
    pub text: String,
    pub spans: Vec<Span>,
    pub tables: Vec<Anchor>,
}

pub fn render(source: &str) -> Rendered {
    // pulldown-cmark doesn't skip a byte-order mark, which would turn a first `# Title` into text.
    let source = source.strip_prefix('\u{feff}').unwrap_or(source);
    let mut b = Builder::default();
    for event in Parser::new_ext(source, OPTIONS) {
        b.event(event);
    }
    b.out
}

/// Escapes text for Pango markup, and drops the control characters markup can't hold.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            '\t' | '\n' => out.push(c),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// A table being collected: its cells are markup, not text in the view.
struct TableBuild {
    table: Table,
    cell: String,
    /// Closing tags for the markup elements open in the current cell.
    closers: Vec<&'static str>,
}

#[derive(Default)]
struct Builder {
    out: Rendered,
    /// Characters in `out.text`.
    len: usize,
    /// Whether anything, text or a table, has been placed yet: no newlines go before it.
    started: bool,
    /// Newlines the text currently ends with, since the last text or table.
    newlines: usize,
    /// Newlines owed before the next block: 1 inside a list, 2 (a blank line) otherwise.
    gap: usize,
    /// Styles open, with the offset each starts at.
    open: Vec<(Style, usize)>,
    /// The next number of each open list, or `None` for a bullet list.
    lists: Vec<Option<u64>>,
    quotes: usize,
    /// `quotes` when each open list item started, so a paragraph can tell whether its nearest
    /// container is the item (a loose list) or a quote inside it.
    item_quotes: Vec<usize>,
    /// A list item's marker, written with the item's first text, so a task box can replace it.
    marker: Option<(String, Style)>,
    /// Code, HTML or front matter being collected, so its trailing newline can be dropped.
    raw: Option<String>,
    table: Option<TableBuild>,
}

impl Builder {
    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(s) => self.text(&s),
            Event::Code(s) => self.inline_literal(&s, Style::Code, "tt"),
            Event::InlineHtml(s) => self.inline_literal(&s, Style::Html, "tt"),
            Event::Html(s) => match &mut self.raw {
                Some(raw) => raw.push_str(&s),
                None => self.inline_literal(&s, Style::Html, "tt"),
            },
            Event::SoftBreak => self.text(" "),
            // U+2028 breaks the line inside the paragraph; a newline would start a new one.
            Event::HardBreak => match &mut self.table {
                Some(t) => t.cell.push('\n'),
                None => self.push("\u{2028}"),
            },
            Event::Rule => {
                self.begin_nested_block();
                let start = self.len;
                self.push(RULE);
                self.span(start, Style::Rule);
                self.gap = self.block_gap();
            }
            Event::TaskListMarker(done) => {
                let task = TASK_BOXES[usize::from(done)].to_owned();
                if let Some((text, Style::Hang { marker, .. })) = &mut self.marker {
                    *text = task;
                    *marker = Marker::Task;
                }
            }
            // Math and footnotes are off in OPTIONS, so these never arrive.
            Event::InlineMath(_) | Event::DisplayMath(_) | Event::FootnoteReference(_) => {}
        }
    }

    fn start(&mut self, tag: Tag) {
        if let Some(t) = &mut self.table {
            match tag {
                Tag::TableHead | Tag::TableRow => t.table.rows.push(Vec::new()),
                Tag::TableCell => t.cell.clear(),
                Tag::Emphasis => t.open("<i>", "</i>"),
                Tag::Strong => t.open("<b>", "</b>"),
                Tag::Strikethrough => t.open("<s>", "</s>"),
                Tag::Link { dest_url, .. } => {
                    let open = format!("<a href=\"{}\">", escape(&dest_url));
                    t.cell.push_str(&open);
                    t.closers.push("</a>");
                }
                Tag::Image { .. } => t.open("<i>", "</i>"),
                _ => {}
            }
            return;
        }
        match tag {
            Tag::Paragraph => {
                // Tight lists have no paragraphs, so one directly in a list item that isn't the
                // item's first block (whose marker would still be pending) is in a loose list:
                // blank line. A quote's paragraphs don't count: a quote always has them.
                if self.marker.is_none() && self.item_quotes.last() == Some(&self.quotes) {
                    self.gap = self.gap.max(2);
                }
                self.begin_block();
            }
            Tag::Heading { level, .. } => {
                self.begin_nested_block();
                self.open_style(Style::Heading(heading_level(level)));
            }
            Tag::BlockQuote(_) => {
                self.begin_nested_block();
                self.quotes += 1;
                self.open_style(Style::Quote);
                self.open_style(Style::Indent {
                    level: self.level(),
                });
            }
            Tag::CodeBlock(_) => self.begin_raw(Style::CodeBlock),
            Tag::HtmlBlock => self.begin_raw(Style::Html),
            Tag::MetadataBlock(_) => self.begin_raw(Style::FrontMatter),
            Tag::List(start) => {
                self.begin_nested_block();
                self.lists.push(start);
            }
            Tag::Item => {
                self.begin_block();
                self.item_quotes.push(self.quotes);
                let depth = self.lists.len();
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        let marker = format!("{n}. ");
                        *n += 1;
                        let digits = u8::try_from(marker.len() - 2).unwrap_or(u8::MAX);
                        (marker, Marker::Number { digits })
                    }
                    _ => {
                        let i = depth.saturating_sub(1) % BULLETS.len();
                        let index = u8::try_from(i).unwrap_or(0);
                        (BULLETS[i].to_owned(), Marker::Bullet(index))
                    }
                };
                let (text, marker) = marker;
                let level = self.level();
                self.marker = Some((text, Style::Hang { marker, level }));
                self.open_style(Style::Indent { level });
            }
            Tag::Table(align) => {
                self.begin_nested_block();
                self.table = Some(TableBuild {
                    table: Table {
                        align,
                        rows: Vec::new(),
                    },
                    cell: String::new(),
                    closers: Vec::new(),
                });
            }
            Tag::Emphasis => self.open_inline(Style::Emphasis),
            Tag::Strong => self.open_inline(Style::Strong),
            Tag::Strikethrough => self.open_inline(Style::Strike),
            Tag::Link { .. } => self.open_inline(Style::Link),
            Tag::Image { .. } => self.open_inline(Style::ImageAlt),
            // Table parts only arrive inside a table, handled above. Footnotes, definition
            // lists, superscript and subscript are off in OPTIONS.
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        if let Some(t) = &mut self.table {
            match tag {
                TagEnd::TableCell => {
                    let cell = std::mem::take(&mut t.cell);
                    if let Some(row) = t.table.rows.last_mut() {
                        row.push(cell);
                    }
                }
                TagEnd::Emphasis
                | TagEnd::Strong
                | TagEnd::Strikethrough
                | TagEnd::Link
                | TagEnd::Image => {
                    // An image with no alt text shows a placeholder, as it does outside tables.
                    if tag == TagEnd::Image && t.cell.ends_with("<i>") {
                        t.cell.push_str("image");
                    }
                    if let Some(closer) = t.closers.pop() {
                        t.cell.push_str(closer);
                    }
                }
                TagEnd::Table => {
                    let table = std::mem::take(&mut self.table).map(|t| t.table);
                    if let Some(table) = table {
                        let anchor = Anchor {
                            offset: self.len,
                            level: self.level(),
                            table,
                        };
                        self.out.tables.push(anchor);
                        self.append(&ANCHOR.to_string());
                    }
                    self.gap = self.block_gap();
                }
                _ => {}
            }
            return;
        }
        match tag {
            TagEnd::Paragraph => self.gap = self.gap.max(2),
            TagEnd::Heading(_) => {
                self.close();
                self.gap = self.block_gap();
            }
            TagEnd::BlockQuote(_) => {
                self.close(); // Indent
                self.close(); // Quote
                self.quotes = self.quotes.saturating_sub(1);
                self.gap = self.block_gap();
            }
            TagEnd::CodeBlock | TagEnd::HtmlBlock | TagEnd::MetadataBlock(_) => {
                let raw = self.raw.take().unwrap_or_default();
                self.push(raw.trim_end_matches(['\n', '\r']));
                self.close();
                self.gap = self.block_gap();
            }
            TagEnd::List(_) => {
                self.lists.pop();
                // max: a loose inner item's paragraph has already asked for a blank line.
                self.gap = self.gap.max(if self.lists.is_empty() { 2 } else { 1 });
            }
            TagEnd::Item => {
                self.item_quotes.pop();
                // An item with no content still shows its marker.
                if self.marker.is_some() {
                    self.push("");
                }
                self.close();
                self.gap = self.gap.max(1);
            }
            TagEnd::Image => {
                if self
                    .open
                    .last()
                    .is_some_and(|&(_, start)| start == self.len)
                {
                    self.push("image");
                }
                self.close();
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link => {
                self.close();
            }
            _ => {}
        }
    }

    fn text(&mut self, s: &str) {
        if let Some(raw) = &mut self.raw {
            raw.push_str(s);
        } else if let Some(t) = &mut self.table {
            t.cell.push_str(&escape(s));
        } else {
            self.push(s);
        }
    }

    /// Inline code or HTML: literal text in its own style, or a markup element in a table cell.
    fn inline_literal(&mut self, s: &str, style: Style, element: &str) {
        if let Some(t) = &mut self.table {
            let markup = format!("<{element}>{}</{element}>", escape(s));
            t.cell.push_str(&markup);
            return;
        }
        let start = self.mark();
        self.push(s);
        self.span(start, style);
    }

    /// Writes text into the view, first paying any owed newlines and the pending list marker.
    fn push(&mut self, s: &str) {
        self.pay_gap();
        if let Some((text, hang)) = self.marker.take() {
            let start = self.len;
            self.append(&text);
            self.span(start, hang);
        }
        self.append(s);
    }

    fn append(&mut self, s: &str) {
        if s.is_empty() {
            return;
        }
        let trailing = s.bytes().rev().take_while(|&b| b == b'\n').count();
        self.newlines = if trailing == s.len() {
            self.newlines + trailing
        } else {
            trailing
        };
        self.started = true;
        self.out.text.push_str(s);
        self.len += s.chars().count();
    }

    /// Every block starts on a new line, and after a blank line unless inside a list.
    fn begin_block(&mut self) {
        self.gap = self.gap.max(1);
        self.pay_gap();
    }

    /// A block other than a paragraph: an item's marker can't wait for this block's text (a
    /// nested item would replace it, a table has none, a code block would style it), so it is
    /// written first, on its own line.
    fn begin_nested_block(&mut self) {
        if self.marker.is_some() {
            self.push("");
        }
        self.begin_block();
    }

    /// Ends the text with `gap` newlines, counting those already there, so nested block starts
    /// (a list, then its first item) don't stack up blank lines.
    fn pay_gap(&mut self) {
        if self.started {
            for _ in self.newlines..self.gap {
                self.append("\n");
            }
        }
        self.gap = 0;
    }

    /// What a block other than a paragraph leaves before the next one: a blank line, or just a
    /// line break inside a list, which a code block or heading in an item mustn't loosen.
    fn block_gap(&self) -> usize {
        if self.lists.is_empty() { 2 } else { 1 }
    }

    fn begin_raw(&mut self, style: Style) {
        self.begin_nested_block();
        self.open_style(style);
        self.raw = Some(String::new());
    }

    /// The offset inline content starts at, once the marker is written, so it isn't styled.
    fn mark(&mut self) -> usize {
        self.push("");
        self.len
    }

    fn open_inline(&mut self, style: Style) {
        let start = self.mark();
        self.open.push((style, start));
    }

    fn open_style(&mut self, style: Style) {
        self.open.push((style, self.len));
    }

    fn close(&mut self) {
        if let Some((style, start)) = self.open.pop() {
            self.span(start, style);
        }
    }

    fn span(&mut self, start: usize, style: Style) {
        if self.len > start {
            self.out.spans.push(Span {
                start,
                end: self.len,
                style,
            });
        }
    }

    fn level(&self) -> u8 {
        u8::try_from(self.lists.len().saturating_add(self.quotes)).unwrap_or(u8::MAX)
    }
}

impl TableBuild {
    fn open(&mut self, open: &str, close: &'static str) {
        self.cell.push_str(open);
        self.closers.push(close);
    }
}

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The text each span of `style` covers.
    fn styled(r: &Rendered, style: Style) -> Vec<String> {
        r.spans
            .iter()
            .filter(|s| s.style == style)
            .map(|s| r.text.chars().skip(s.start).take(s.end - s.start).collect())
            .collect()
    }

    #[test]
    fn heading_and_paragraph_are_separated_by_a_blank_line() {
        let r = render("# Title\n\nSome *body* text.\n");
        assert_eq!(r.text, "Title\n\nSome body text.");
        assert_eq!(styled(&r, Style::Heading(1)), ["Title"]);
        assert_eq!(styled(&r, Style::Emphasis), ["body"]);
    }

    #[test]
    fn inline_styles() {
        let r = render("**b** ~~s~~ `c` [l](https://x.org)\n");
        assert_eq!(r.text, "b s c l");
        assert_eq!(styled(&r, Style::Strong), ["b"]);
        assert_eq!(styled(&r, Style::Strike), ["s"]);
        assert_eq!(styled(&r, Style::Code), ["c"]);
        assert_eq!(styled(&r, Style::Link), ["l"]);
    }

    #[test]
    fn offsets_count_characters_not_bytes() {
        let r = render("é **ü**\n");
        assert_eq!(r.spans[0].start, 2);
        assert_eq!(styled(&r, Style::Strong), ["ü"]);
    }

    #[test]
    fn tight_lists_have_markers_and_no_blank_lines() {
        let r = render("- one\n- two\n  - deep\n\n3. three\n4. four\n");
        assert_eq!(r.text, "• one\n• two\n◦ deep\n\n3. three\n4. four");
        assert_eq!(styled(&r, Style::Indent { level: 2 }), ["◦ deep"]);
        let hang = Style::Hang {
            marker: Marker::Bullet(1),
            level: 2,
        };
        assert_eq!(styled(&r, hang), ["◦ "]);
    }

    #[test]
    fn task_boxes_replace_the_bullet() {
        let r = render("- [x] done\n- [ ] todo\n");
        assert_eq!(r.text, "☑ done\n☐ todo");
    }

    #[test]
    fn empty_item_keeps_its_marker() {
        assert_eq!(render("-\n").text, "• ");
    }

    #[test]
    fn code_block_drops_its_trailing_newline() {
        let r = render("```rust\nlet x = 1;\n\nlet y = 2;\n```\n\nafter\n");
        assert_eq!(r.text, "let x = 1;\n\nlet y = 2;\n\nafter");
        assert_eq!(styled(&r, Style::CodeBlock), ["let x = 1;\n\nlet y = 2;"]);
    }

    #[test]
    fn front_matter_is_a_block_not_a_rule_and_heading() {
        let r = render("---\nname: x\n---\n\n# Real\n");
        assert_eq!(styled(&r, Style::FrontMatter), ["name: x"]);
        assert_eq!(styled(&r, Style::Heading(1)), ["Real"]);
        assert!(styled(&r, Style::Heading(2)).is_empty());
    }

    #[test]
    fn rule_after_content() {
        let r = render("a\n\n***\n\nb\n");
        assert_eq!(r.text, format!("a\n\n{RULE}\n\nb"));
        assert_eq!(styled(&r, Style::Rule), [RULE]);
    }

    #[test]
    fn raw_html_stays_literal() {
        let r = render("<div>\nhi\n</div>\n\ntext <b>x</b> <!-- c -->\n");
        assert_eq!(
            styled(&r, Style::Html),
            ["<div>\nhi\n</div>", "<b>", "</b>", "<!-- c -->"]
        );
        assert!(r.text.ends_with("text <b>x</b> <!-- c -->"));
    }

    #[test]
    fn byte_order_mark_is_skipped() {
        let r = render("\u{feff}# Title\n");
        assert_eq!(styled(&r, Style::Heading(1)), ["Title"]);
    }

    #[test]
    fn extensions_outside_the_three_stay_literal() {
        // Math, footnote references and smart punctuation are all off.
        let r = render("$x$ and \"q\" -- [^1]\n");
        assert_eq!(r.text, "$x$ and \"q\" -- [^1]");
    }

    #[test]
    fn hard_break_stays_inside_the_paragraph() {
        assert_eq!(render("a  \nb\n").text, "a\u{2028}b");
    }

    #[test]
    fn quote_indents_and_dims() {
        let r = render("> quoted\n\nplain\n");
        assert_eq!(styled(&r, Style::Quote), ["quoted"]);
        assert_eq!(styled(&r, Style::Indent { level: 1 }), ["quoted"]);
    }

    #[test]
    fn image_shows_its_alt_text() {
        let r = render("![a cat](cat.png) ![](x.png)\n");
        assert_eq!(styled(&r, Style::ImageAlt), ["a cat", "image"]);
    }

    #[test]
    fn table_cells_are_escaped_markup_at_an_anchor() {
        let r =
            render("before\n\n| a < b | **c** |\n|:--|--:|\n| `x&y` | [l](u?a=\"1\") |\n\nafter\n");
        assert_eq!(r.text, "before\n\n\u{fffc}\n\nafter");
        assert_eq!(r.tables.len(), 1);
        assert_eq!(r.tables[0].offset, 8);
        let table = &r.tables[0].table;
        assert_eq!(table.align, [Alignment::Left, Alignment::Right]);
        assert_eq!(table.rows[0], ["a &lt; b", "<b>c</b>"]);
        assert_eq!(
            table.rows[1],
            ["<tt>x&amp;y</tt>", "<a href=\"u?a=&quot;1&quot;\">l</a>"]
        );
    }

    #[test]
    fn text_after_a_table_gets_its_own_line() {
        // A table first in the file, then two in a row: each anchor is a character of its own.
        let r = render("| a |\n|---|\n| b |\n\n| c |\n|---|\n\nafter\n");
        let offsets: Vec<usize> = r.tables.iter().map(|a| a.offset).collect();
        assert_eq!(offsets, [0, 3]);
        assert_eq!(r.text, "\u{fffc}\n\n\u{fffc}\n\nafter");
    }

    #[test]
    fn deep_quotes_do_not_overflow() {
        let r = render(&format!("{} x\n", ">".repeat(300)));
        assert_eq!(r.text, "x");
    }

    #[test]
    fn item_starting_with_a_nested_list_keeps_its_marker() {
        assert_eq!(render("- - a\n").text, "• \n◦ a");
        assert_eq!(render("1. - a\n").text, "1. \n◦ a");
    }

    #[test]
    fn item_starting_with_a_table_or_code_writes_its_marker_first() {
        let r = render("- | a |\n  |---|\n  | b |\n");
        assert_eq!(r.text, "• \n\u{fffc}");
        assert_eq!((r.tables[0].offset, r.tables[0].level), (3, 1));
        // The item's indent covers the table, so it sits under the item's text.
        assert_eq!(styled(&r, Style::Indent { level: 1 }), ["• \n\u{fffc}"]);
        let r = render("- ```\n  x\n  ```\n");
        assert_eq!(r.text, "• \nx");
        assert_eq!(styled(&r, Style::CodeBlock), ["x"]);
    }

    #[test]
    fn number_markers_carry_their_width() {
        let r = render("9. a\n10. b\n");
        let digits: Vec<u8> = r
            .spans
            .iter()
            .filter_map(|s| match s.style {
                Style::Hang {
                    marker: Marker::Number { digits },
                    ..
                } => Some(digits),
                _ => None,
            })
            .collect();
        assert_eq!(digits, [1, 2]);
    }

    #[test]
    fn only_the_marker_hangs() {
        let r = render("- first\n\n  second\n");
        let hang = |marker| Style::Hang { marker, level: 1 };
        assert_eq!(styled(&r, hang(Marker::Bullet(0))), ["• "]);
        assert_eq!(
            styled(&r, Style::Indent { level: 1 }),
            ["• first\n\nsecond"]
        );
        let r = render("- [ ] task\n");
        assert_eq!(styled(&r, hang(Marker::Task)), ["☐ "]);
    }

    #[test]
    fn table_in_a_quote_is_inside_the_quote() {
        let r = render("> | a |\n> |---|\n");
        assert_eq!(r.tables[0].level, 1);
        assert_eq!(styled(&r, Style::Indent { level: 1 }), ["\u{fffc}"]);
    }

    #[test]
    fn loose_nested_list_keeps_its_blank_line() {
        assert_eq!(render("- a\n\n  - b\n\n  c\n").text, "• a\n\n◦ b\n\nc");
    }

    #[test]
    fn blocks_inside_a_tight_list_keep_it_tight() {
        assert_eq!(render("- > q\n").text, "• \nq");
        assert_eq!(render("- a\n  > q\n").text, "• a\nq");
        assert_eq!(render("- ```\n  x\n  ```\n- y\n").text, "• \nx\n• y");
        assert_eq!(render("- # H\n  text\n").text, "• \nH\ntext");
    }

    #[test]
    fn empty_alt_text_in_a_table_shows_a_placeholder() {
        let r = render("| ![](x.png) |\n|---|\n");
        assert_eq!(r.tables[0].table.rows[0], ["<i>image</i>"]);
    }

    #[test]
    fn escape_handles_markup_characters_and_controls() {
        assert_eq!(escape("<&>\"'\u{1}\tz"), "&lt;&amp;&gt;&quot;&#39;\tz");
    }
}
