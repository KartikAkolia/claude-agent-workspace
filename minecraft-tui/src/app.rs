//! The event loop and key handling. One mode at a time: the dashboard, a confirmation, the
//! settings form, or a running command's pane.

use crate::{
    actions::{self, ACTIONS, Action, Next, Plan},
    config::{self, Config},
    form::Form,
    logs::{LogTail, LogView},
    pane::Pane,
    probe::{self, Snapshot},
    ui,
};
use ratatui::{
    DefaultTerminal,
    crossterm::{
        event::{
            self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEvent,
            KeyEventKind, KeyModifiers,
        },
        execute,
    },
    layout::Rect,
};
use std::{
    io,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, Sender},
    },
    time::{Duration, Instant},
};

/// Set by SIGTERM, SIGHUP or SIGINT, so the loop ends normally and the terminal is restored.
static SIGNALLED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    SIGNALLED.store(true, Ordering::Relaxed);
}

pub fn catch_signals() {
    for sig in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
        unsafe {
            libc::signal(sig, on_signal as *const () as libc::sighandler_t);
        }
    }
}

/// After a pane opens, a command ends or a confirmation appears, keys count only once the
/// keyboard has been quiet this long. A held key (crossterm reports auto-repeat as fresh presses
/// on most terminals) or keys typed ahead then can't answer pkexec, close a pane and rerun the
/// action, or confirm. It is longer than the usual auto-repeat delay (X's default is 660 ms).
const SETTLE: Duration = Duration::from_millis(700);

/// A finished command's result is on screen at least this long before a key can close it, so
/// a single key typed ahead doesn't close it unseen.
const RESULT_SHOWN: Duration = Duration::from_millis(400);

pub enum Mode {
    Normal,
    /// A plan waiting for y. A form it came from is kept, so n goes back to the edits.
    Confirm(Plan, Option<Form>),
    Form(Form),
    Pane(Pane),
}

pub struct App {
    pub cfg: Config,
    pub snapshot: Option<Snapshot>,
    pub selected: usize,
    pub mode: Mode,
    pub message: Option<(String, Instant)>,
    pub log: LogTail,
    pub log_view: LogView,
    probe_rx: Receiver<Snapshot>,
    refresh: Sender<()>,
    /// When the open pane's command was first seen to have ended (the dashboard refreshes once
    /// then, and its result stays up at least RESULT_SHOWN).
    pane_ended: Option<Instant>,
    /// Set by the changes SETTLE describes; cleared by the first key after a quiet gap.
    settle: bool,
    last_key: Option<Instant>,
    quit: bool,
}

impl App {
    pub fn new(cfg: Config) -> Self {
        let (probe_rx, refresh) = probe::spawn(cfg.dir.clone());
        Self {
            cfg,
            snapshot: None,
            selected: 0,
            mode: Mode::Normal,
            message: None,
            log: LogTail::start(config::SERVER),
            log_view: LogView::default(),
            probe_rx,
            refresh,
            pane_ended: None,
            settle: false,
            last_key: None,
            quit: false,
        }
    }

    pub fn run(mut self, terminal: &mut DefaultTerminal) -> io::Result<()> {
        // A paste then arrives as one event, never as keys that could confirm or submit.
        execute!(io::stdout(), EnableBracketedPaste)?;
        let result = self.event_loop(terminal);
        let _ = execute!(io::stdout(), DisableBracketedPaste);
        result
    }

    fn event_loop(&mut self, terminal: &mut DefaultTerminal) -> io::Result<()> {
        loop {
            while let Ok(snapshot) = self.probe_rx.try_recv() {
                self.snapshot = Some(snapshot);
            }
            self.note_pane_end();
            terminal.draw(|frame| ui::draw(frame, self))?;
            if self.quit || SIGNALLED.load(Ordering::Relaxed) {
                return Ok(());
            }
            if !event::poll(Duration::from_millis(100))? {
                continue;
            }
            let area = Rect::from(terminal.size()?);
            match event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => self.on_key(key, area),
                Event::Paste(text) => self.on_paste(&text),
                _ => {}
            }
        }
    }

    pub fn say(&mut self, message: impl Into<String>) {
        self.message = Some((message.into(), Instant::now()));
    }

    /// Notes a pane's command ending, from the loop or from a key that arrives first.
    fn note_pane_end(&mut self) {
        if let Mode::Pane(pane) = &self.mode
            && self.pane_ended.is_none()
            && pane.exit().is_some()
        {
            self.pane_ended = Some(Instant::now());
            self.settle = true;
            let _ = self.refresh.send(());
        }
    }

    fn on_key(&mut self, key: KeyEvent, area: Rect) {
        let now = Instant::now();
        let quiet = self.last_key.is_none_or(|at| now - at >= SETTLE);
        self.last_key = Some(now);
        self.note_pane_end();
        let running = matches!(self.mode, Mode::Pane(ref p) if p.exit().is_none());
        // The too-small screen hides the dashboard, so only its "q quits" works there. A running
        // command still gets its keys (it's drawn full-screen): it may be asking for a password.
        if (area.width < ui::MIN_SIZE.0 || area.height < ui::MIN_SIZE.1) && !running {
            let ctrl_c =
                key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL);
            self.quit = key.code == KeyCode::Char('q') || ctrl_c;
            return;
        }
        // Scrolling, moving the selection and quitting the dashboard can't do harm, so they
        // never wait.
        let navigation = matches!(
            key.code,
            KeyCode::Up | KeyCode::Down | KeyCode::PageUp | KeyCode::PageDown | KeyCode::End
        ) && !running
            || matches!(self.mode, Mode::Normal) && key.code == KeyCode::Char('q');
        if self.settle && !quiet && !navigation {
            return;
        }
        if !navigation {
            self.settle = false;
        }
        match std::mem::replace(&mut self.mode, Mode::Normal) {
            Mode::Normal => self.on_normal(key, area),
            Mode::Confirm(plan, form) => match key.code {
                KeyCode::Char('y' | 'Y') => self.start(plan, area),
                KeyCode::Char('n' | 'N') | KeyCode::Esc => {
                    if let Some(form) = form {
                        self.mode = Mode::Form(form);
                    }
                }
                _ => self.mode = Mode::Confirm(plan, form),
            },
            Mode::Form(form) => self.on_form(form, key),
            Mode::Pane(pane) => self.on_pane(pane, key, area),
        }
    }

    fn on_paste(&mut self, text: &str) {
        match &mut self.mode {
            Mode::Form(form) => {
                let field = form.field();
                field.value.extend(text.chars().filter(|c| !c.is_control()));
            }
            Mode::Pane(pane) if pane.exit().is_none() => pane.send_paste(text),
            _ => {}
        }
    }

    fn on_normal(&mut self, key: KeyEvent, area: Rect) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('c') if ctrl => self.quit = true,
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Up | KeyCode::Char('k') => {
                self.selected = (self.selected + ACTIONS.len() - 1) % ACTIONS.len();
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.selected = (self.selected + 1) % ACTIONS.len()
            }
            KeyCode::Enter => self.trigger(ACTIONS[self.selected], area),
            KeyCode::PageUp => self.log_view.scroll = self.log_view.scroll.saturating_add(10),
            KeyCode::PageDown => self.log_view.scroll = self.log_view.scroll.saturating_sub(10),
            KeyCode::End | KeyCode::Char('G') => self.log_view.scroll = 0,
            KeyCode::Char(c) if !ctrl => {
                if let Some(i) = ACTIONS.iter().position(|a| a.key() == c) {
                    self.selected = i;
                    self.trigger(ACTIONS[i], area);
                }
            }
            _ => {}
        }
    }

    fn trigger(&mut self, action: Action, area: Rect) {
        match actions::next(action, &self.cfg, self.snapshot.as_ref()) {
            Next::Message(m) => self.say(m),
            Next::OpenForm => self.mode = Mode::Form(Form::new(self.snapshot.as_ref())),
            Next::Run(plan) if plan.confirm.is_some() => {
                self.settle = true;
                self.mode = Mode::Confirm(plan, None);
            }
            Next::Run(plan) => self.start(plan, area),
        }
    }

    fn start(&mut self, plan: Plan, area: Rect) {
        let inner = ui::pane_inner(area);
        match Pane::spawn(plan.title.clone(), &plan.argv, inner.height, inner.width) {
            Ok(pane) => {
                self.pane_ended = None;
                self.settle = true;
                self.mode = Mode::Pane(pane);
            }
            Err(e) => self.say(format!("Could not start {}: {e}", plan.title)),
        }
    }

    fn on_form(&mut self, mut form: Form, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => return,
            KeyCode::Up | KeyCode::BackTab => form.move_by(-1),
            KeyCode::Down | KeyCode::Tab => form.move_by(1),
            KeyCode::Backspace => {
                form.field().value.pop();
            }
            KeyCode::Char('u') if ctrl => form.field().value.clear(),
            KeyCode::Char(c) if !ctrl => form.field().value.push(c),
            KeyCode::Enter => match form.changes() {
                Ok(c) if c.summary.is_empty() => self.say("Nothing changed."),
                Err(e) => self.say(e),
                Ok(c) => match self.cfg.root_command(&c.args, &c.env) {
                    Ok(argv) => {
                        let confirm = format!(
                            "Apply with minecraft-twingate.sh update, as root?\n\n{}\n\nThe server is recreated (players are disconnected), and the stack starts if it's stopped.",
                            c.summary.join("\n")
                        );
                        let plan = Plan {
                            title: "Apply settings".into(),
                            argv,
                            confirm: Some(confirm),
                        };
                        self.settle = true;
                        self.mode = Mode::Confirm(plan, Some(form));
                        return;
                    }
                    Err(e) => self.say(e),
                },
            },
            _ => {}
        }
        self.mode = Mode::Form(form);
    }

    fn on_pane(&mut self, mut pane: Pane, key: KeyEvent, area: Rect) {
        let page = ui::pane_inner(area).height.max(2) as isize - 1;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::PageUp => pane.scroll_by(page),
            KeyCode::PageDown => pane.scroll_by(-page),
            _ if pane.exit().is_some() => {
                let shown = self
                    .pane_ended
                    .is_some_and(|at| at.elapsed() >= RESULT_SHOWN);
                if shown && matches!(key.code, KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q')) {
                    self.settle = true;
                    let _ = self.refresh.send(());
                    return;
                }
            }
            // The way out of a command that ignores Ctrl-C or hangs. A terminal sends Ctrl-] as
            // 0x1d, which crossterm reports as Ctrl-5.
            KeyCode::Char(']' | '5') if ctrl => {
                let stopped = pane.hang_up();
                let pid = pane.pid().map_or(String::new(), |p| format!(" (pid {p})"));
                drop(pane);
                self.settle = true;
                let _ = self.refresh.send(());
                self.say(if stopped {
                    "Left the command and hung it up.".to_string()
                } else {
                    format!("Left the command; it runs as root and may still be running{pid}.")
                });
                return;
            }
            _ => pane.send_key(&key),
        }
        self.mode = Mode::Pane(pane);
    }
}
