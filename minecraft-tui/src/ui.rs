//! Drawing. The layout is the header, the actions list on the left, status and the server log on
//! the right, and a footer; confirmations, the settings form and command panes float above.

use crate::{
    actions::ACTIONS,
    app::{App, Mode},
    config,
    form::Form,
    pane::Pane,
    probe::{Route, Snapshot},
    slp,
};
use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, Clear, List, ListItem, ListState, Paragraph, Wrap},
};
use std::time::Duration;
use tui_term::widget::{Cursor, PseudoTerminal};

const MESSAGE_TIME: Duration = Duration::from_secs(8);
const LABEL: usize = 10;
/// Below this the panels can't show their rows, so the screen says so instead.
pub const MIN_SIZE: (u16, u16) = (64, 18);

/// A command's pane covers everything between the header and the footer.
pub fn pane_area(area: Rect) -> Rect {
    Rect {
        y: area.y + 1,
        height: area.height.saturating_sub(2),
        ..area
    }
}

pub fn pane_inner(area: Rect) -> Rect {
    Block::bordered().inner(pane_area(area))
}

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    if area.width < MIN_SIZE.0 || area.height < MIN_SIZE.1 {
        // A command may be asking for something, so it keeps the whole screen.
        match &mut app.mode {
            Mode::Pane(pane) if pane.exit().is_none() => draw_pane(frame, area, pane),
            _ => draw_too_small(frame, area),
        }
        return;
    }
    let [header, body, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Fill(1),
        Constraint::Length(1),
    ])
    .areas(area);
    draw_header(frame, header, app.snapshot.as_ref());
    draw_footer(frame, footer, app);
    if let Mode::Pane(pane) = &mut app.mode {
        draw_pane(frame, pane_area(area), pane);
        return;
    }
    let [left, right] =
        Layout::horizontal([Constraint::Length(24), Constraint::Fill(1)]).areas(body);
    let (server, network) = match &app.snapshot {
        None => (vec![Line::from("reading state...".dark_gray())], Vec::new()),
        Some(snap) => (server_lines(snap), network_lines(snap, app)),
    };
    // Tall enough for the longer panel, leaving the log at least 5 rows.
    let rows = server.len().max(network.len()) as u16 + 2;
    let [status, log] = Layout::vertical([
        Constraint::Length(rows.min(right.height.saturating_sub(5))),
        Constraint::Fill(1),
    ])
    .areas(right);
    draw_actions(frame, left, app.selected);
    let [s, n] = Layout::horizontal([Constraint::Fill(1), Constraint::Fill(1)]).areas(status);
    frame.render_widget(
        Paragraph::new(server).block(Block::bordered().title(" Server ")),
        s,
    );
    frame.render_widget(
        Paragraph::new(network).block(Block::bordered().title(" Twingate ")),
        n,
    );
    draw_log(frame, log, app);
    match &app.mode {
        Mode::Confirm(plan, _) => draw_confirm(frame, plan.confirm.as_deref().unwrap_or("")),
        Mode::Form(form) => draw_form(frame, form),
        Mode::Normal | Mode::Pane(_) => {}
    }
}

fn draw_too_small(frame: &mut Frame, area: Rect) {
    let text = vec![
        Line::from("Terminal too small".bold()),
        Line::from(format!(
            "{}x{} needed, {}x{} now",
            MIN_SIZE.0, MIN_SIZE.1, area.width, area.height
        )),
        Line::from("q quits".dark_gray()),
    ];
    let rect = area.centered_vertically(Constraint::Length(3));
    frame.render_widget(
        Paragraph::new(text).centered().wrap(Wrap { trim: true }),
        rect,
    );
}

fn state_color(status: &str) -> Color {
    match status {
        "running" | "healthy" | "Online" => Color::Green,
        "restarting" | "starting" | "paused" | "created" | "Authentication" | "Offline" => {
            Color::Yellow
        }
        "unknown" => Color::DarkGray,
        _ => Color::Red,
    }
}

fn dot(status: &str) -> Span<'static> {
    Span::styled("● ", Style::new().fg(state_color(status)))
}

fn row<'a>(label: &str, value: impl Into<Vec<Span<'a>>>) -> Line<'a> {
    let mut spans = vec![Span::styled(
        format!("{label:<LABEL$}"),
        Style::new().dark_gray(),
    )];
    spans.extend(value.into());
    Line::from(spans)
}

/// The Connector's state: its own "State:" line while it runs, else the container's status.
fn connector_status(snap: &Snapshot) -> String {
    if snap.docker_error.is_some() {
        return "unknown".into();
    }
    match &snap.connector {
        None => "missing".into(),
        Some(c) if c.running() => snap
            .connector_state
            .clone()
            .unwrap_or_else(|| c.status.clone()),
        Some(c) => c.status.clone(),
    }
}

fn server_status(snap: &Snapshot) -> String {
    if snap.docker_error.is_some() {
        return "unknown".into();
    }
    snap.server
        .as_ref()
        .map_or("missing".into(), |c| c.status.clone())
}

fn draw_header(frame: &mut Frame, area: Rect, snap: Option<&Snapshot>) {
    let mut spans = vec![" Minecraft + Twingate ".bold().reversed(), " ".into()];
    match snap {
        None => spans.push(" reading state...".dark_gray()),
        Some(snap) if snap.docker_error.is_some() => {
            spans.push(" ● docker unreachable".red());
        }
        Some(snap) => {
            let (server, connector) = (server_status(snap), connector_status(snap));
            spans.extend([
                " ".into(),
                dot(&server),
                format!("server {server}  ").into(),
            ]);
            spans.extend([dot(&connector), format!("connector {connector}  ").into()]);
            if let Some(Ok(p)) = &snap.ping {
                spans
                    .push(format!("players {}/{}", slp::count(p.online), slp::count(p.max)).into());
            }
        }
    }
    frame.render_widget(Line::from(spans), area);
}

fn draw_actions(frame: &mut Frame, area: Rect, selected: usize) {
    let items: Vec<ListItem> = ACTIONS
        .iter()
        .map(|a| {
            ListItem::new(Line::from(vec![
                Span::styled(format!(" {} ", a.key()), Style::new().cyan().bold()),
                Span::raw(a.label()),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(Block::bordered().title(" Actions "))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶");
    frame.render_stateful_widget(
        list,
        area,
        &mut ListState::default().with_selected(Some(selected)),
    );
}

/// docker's timestamps, shortened to the minute; Docker's zero time means it never happened.
fn when(at: &str) -> String {
    if at.starts_with("0001-") || at.len() < 16 {
        return "never".into();
    }
    format!("{} UTC", at[..16].replace('T', " "))
}

fn server_lines(snap: &Snapshot) -> Vec<Line<'static>> {
    if let Some(e) = &snap.docker_error {
        return vec![
            Line::from("Docker isn't answering:".red()),
            Line::from(e.clone()),
        ];
    }
    let Some(c) = &snap.server else {
        return vec![
            Line::from("No minecraft-server container."),
            Line::from("Install (i) sets the stack up.".dark_gray()),
        ];
    };
    let mut state = vec![dot(&c.status), c.status.clone().into()];
    if c.running() && c.health != "none" {
        state.push(format!(", {}", c.health).fg(state_color(&c.health)));
    }
    let mut lines = vec![row("State", state)];
    if c.running() {
        lines.push(row("Started", vec![when(&c.started_at).into()]));
    } else {
        let code = if c.exit_code == 0 {
            String::new()
        } else {
            format!(" (exit {})", c.exit_code)
        };
        lines.push(row(
            "Stopped",
            vec![format!("{}{code}", when(&c.finished_at)).into()],
        ));
    }
    if c.restarts > 0 {
        lines.push(row("Restarts", vec![c.restarts.to_string().yellow()]));
    }
    lines.push(row(
        "Settings",
        vec![
            format!(
                "{} {}, {} heap",
                snap.setting("TYPE"),
                snap.setting("VERSION"),
                snap.setting("MEMORY")
            )
            .into(),
        ],
    ));
    match &snap.ping {
        Some(Ok(p)) => {
            let mut players =
                vec![format!("{}/{}", slp::count(p.online), slp::count(p.max)).bold()];
            if !p.players.is_empty() {
                players.push(format!("  {}", p.players.join(", ")).into());
            }
            lines.push(row("Version", vec![p.version.clone().into()]));
            lines.push(row("Players", players));
            lines.push(row("MOTD", vec![p.motd.clone().into()]));
        }
        Some(Err(e)) => lines.push(row("Ping", vec![e.clone().yellow()])),
        None => {}
    }
    lines
}

fn network_lines(snap: &Snapshot, app: &App) -> Vec<Line<'static>> {
    let state = connector_status(snap);
    let mut spans = vec![dot(&state), state.clone().into()];
    if let Some(c) = snap
        .connector
        .as_ref()
        .filter(|c| c.running() && c.health == "unhealthy")
    {
        spans.push(format!(", {}", c.health).red());
    }
    let mut lines = vec![row("Connector", spans)];
    if !snap.other_connectors.is_empty() {
        lines.push(row(
            "Also up",
            vec![snap.other_connectors.join(", ").yellow()],
        ));
    }
    let address = snap
        .server_ip
        .as_deref()
        .map_or("unknown".into(), |ip| format!("{ip}:25565"));
    lines.push(row("Resource", vec![address.into()]));
    let route = match &snap.route {
        Route::Pinned => format!("via {}", config::BRIDGE).green(),
        Route::Elsewhere(dev) => format!("via {dev}: run Update (u)").yellow(),
        Route::Unknown => "unknown".dark_gray(),
    };
    lines.push(row("Route", vec![route]));
    if let Some(Ok(p)) = &snap.ping {
        lines.push(row("Ping", vec![format!("{} ms", p.latency_ms).into()]));
    }
    let installed = if snap.installed {
        "".into()
    } else {
        " (not installed)".yellow()
    };
    lines.push(row(
        "Stack",
        vec![app.cfg.dir.display().to_string().into(), installed],
    ));
    lines
}

fn draw_log(frame: &mut Frame, area: Rect, app: &mut App) {
    let height = area.height.saturating_sub(2) as usize;
    let lines = app.log.window(height, &mut app.log_view);
    let title = match app.log_view.scroll {
        0 => " Server log ".to_string(),
        n => format!(" Server log, {n} lines up (End follows) "),
    };
    let lines: Vec<Line> = lines
        .into_iter()
        .map(|l| {
            let style = if l.contains("ERROR") || l.contains("Exception") {
                Style::new().red()
            } else if l.contains("WARN") {
                Style::new().yellow()
            } else {
                Style::new()
            };
            Line::styled(l, style)
        })
        .collect();
    frame.render_widget(
        Paragraph::new(lines).block(Block::bordered().title(title)),
        area,
    );
}

fn draw_footer(frame: &mut Frame, area: Rect, app: &App) {
    if let Some((m, at)) = &app.message
        && at.elapsed() < MESSAGE_TIME
    {
        frame.render_widget(Line::from(format!(" {m}").yellow()), area);
        return;
    }
    // Keys first, so a narrow terminal cuts the description, not the keys.
    let (keys, help) = match &app.mode {
        Mode::Normal => (
            " q quit · ↑↓ Enter · letter runs · PgUp/PgDn log ",
            ACTIONS[app.selected].help(),
        ),
        Mode::Confirm(..) => (" y yes · n/Esc no ", ""),
        Mode::Form(_) => (
            " Enter apply · Esc cancel · Tab/↑↓ move · Ctrl-U clear ",
            "",
        ),
        Mode::Pane(pane) if pane.exit().is_some() => (" Enter/Esc/q close · PgUp/PgDn scroll ", ""),
        Mode::Pane(_) => (
            " keys go to the command · Ctrl-C interrupt · Ctrl-] leave · PgUp/PgDn scroll ",
            "",
        ),
    };
    frame.render_widget(
        Line::from(vec![keys.reversed(), format!(" {help}").dark_gray()]),
        area,
    );
}

fn popup(frame: &mut Frame, width: u16, height: u16) -> Rect {
    let area = frame
        .area()
        .centered(Constraint::Length(width), Constraint::Length(height));
    frame.render_widget(Clear, area);
    area
}

/// Rows TEXT takes when word-wrapped to WIDTH columns, counted the way Paragraph wraps words.
fn wrapped_rows(text: &str, width: u16) -> u16 {
    let width = usize::from(width.max(1));
    text.lines()
        .map(|line| {
            let mut rows = 1;
            let mut used = 0;
            for word in line.split_whitespace() {
                let w = word.chars().count();
                if used > 0 && used + 1 + w <= width {
                    used += 1 + w;
                    continue;
                }
                if used > 0 {
                    rows += 1;
                }
                // A word longer than the width is broken across rows.
                rows += (w - 1) / width;
                used = (w - 1) % width + 1;
            }
            rows
        })
        .sum::<usize>()
        .try_into()
        .unwrap_or(u16::MAX)
}

fn draw_confirm(frame: &mut Frame, text: &str) {
    let width = 72.min(frame.area().width);
    let rows = wrapped_rows(text, width.saturating_sub(2));
    let area = popup(frame, width, rows.saturating_add(2));
    // The keys live in the border, so wrapping can never push them out of sight.
    let block = Block::bordered()
        .title(" Confirm ")
        .title_bottom(Line::from(" y: yes · n/Esc: no ").centered())
        .border_style(Style::new().yellow());
    let lines: Vec<Line> = text.lines().map(|l| Line::from(l.to_string())).collect();
    frame.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(block),
        area,
    );
}

fn draw_form(frame: &mut Frame, form: &Form) {
    let mut lines = vec![Line::from(
        "The script checks each value as it applies them.".dark_gray(),
    )];
    for (i, f) in form.fields.iter().enumerate() {
        let changed = if f.value != f.original { "*" } else { " " };
        let mut value = Span::raw(f.value.clone());
        let mut label = Span::raw(format!("{changed} {:<18}", f.label));
        if i == form.selected {
            value = Span::styled(format!("{}▏", f.value), Style::new().reversed());
            label = label.bold().cyan();
        }
        lines.push(Line::from(vec![label, value]));
    }
    let area = popup(frame, 76, lines.len() as u16 + 2);
    let block = Block::bordered()
        .title(" Edit settings ")
        .title_bottom(Line::from(" Enter apply · Esc cancel ").centered())
        .border_style(Style::new().cyan());
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

fn draw_pane(frame: &mut Frame, area: Rect, pane: &mut Pane) {
    frame.render_widget(Clear, area);
    let (status, color) = match pane.exit() {
        None => ("running".to_string(), Color::Cyan),
        Some((true, _)) => ("done".to_string(), Color::Green),
        Some((false, code)) => (format!("failed, exit {code}"), Color::Red),
    };
    let mut title = format!(" {}: {status} ", pane.title);
    if pane.scrolled() > 0 {
        title.push_str(&format!("({} lines up) ", pane.scrolled()));
    }
    let block = Block::bordered()
        .title(Line::from(title).bold())
        .border_style(Style::new().fg(color));
    let inner = block.inner(area);
    pane.resize(inner.height, inner.width);
    // A finished command's cursor would look like it still waits for input.
    let cursor = Cursor::default().visibility(pane.exit().is_none() && pane.scrolled() == 0);
    pane.with_screen(|screen| {
        frame.render_widget(
            PseudoTerminal::new(screen).block(block).cursor(cursor),
            area,
        );
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn when_formats_docker_times() {
        assert_eq!(when("2026-11-27T13:29:23.09Z"), "2026-11-27 13:29 UTC");
        assert_eq!(when("0001-01-01T00:00:00Z"), "never");
    }

    #[test]
    fn counts_wrapped_rows() {
        assert_eq!(wrapped_rows("abc def", 7), 1);
        assert_eq!(wrapped_rows("abc def", 6), 2);
        assert_eq!(wrapped_rows("one\n\ntwo", 10), 3);
        assert_eq!(wrapped_rows("abcdefghij", 4), 3);
    }
}
