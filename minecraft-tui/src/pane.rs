//! Runs one command in a pseudo-terminal and keeps its screen, linutil-style: prompts from pkexec,
//! the script's token questions and rcon-cli all work, because the command sees a real terminal.

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::{
    io::{Read, Write},
    sync::{
        Arc, Mutex, RwLock,
        mpsc::{self, Sender},
    },
    thread,
};

pub struct Pane {
    pub title: String,
    parser: Arc<RwLock<vt100::Parser>>,
    master: Box<dyn MasterPty + Send>,
    /// Keys go through a thread: a command that stops reading would otherwise block the UI
    /// once the terminal's input buffer fills.
    input: Sender<Vec<u8>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    pid: Option<u32>,
    /// (success, exit code), set once the command has ended and its output is read.
    exit: Arc<Mutex<Option<(bool, u32)>>>,
    size: (u16, u16),
}

const SCROLLBACK: usize = 5000;

impl Pane {
    pub fn spawn(title: String, argv: &[String], rows: u16, cols: u16) -> Result<Self, String> {
        let (rows, cols) = (rows.max(2), cols.max(2));
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| e.to_string())?;
        let mut cmd = CommandBuilder::new(&argv[0]);
        cmd.args(&argv[1..]);
        cmd.env("TERM", "xterm-256color");
        if let Ok(home) = std::env::var("HOME") {
            cmd.cwd(home);
        }
        let mut child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
        // Only the child may hold the terminal's other end, or reads never see it close.
        drop(pair.slave);
        let killer = child.clone_killer();
        let pid = child.process_id();
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let mut writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let parser = Arc::new(RwLock::new(vt100::Parser::new(rows, cols, SCROLLBACK)));
        let exit = Arc::new(Mutex::new(None));

        let (input, keys) = mpsc::channel::<Vec<u8>>();
        thread::spawn(move || {
            while let Ok(bytes) = keys.recv() {
                if writer
                    .write_all(&bytes)
                    .and_then(|()| writer.flush())
                    .is_err()
                {
                    return;
                }
            }
        });
        let output = {
            let parser = parser.clone();
            thread::spawn(move || {
                let mut buf = [0u8; 8192];
                // Linux reports a terminal with no writers left as EIO, not as end of file.
                while let Ok(n @ 1..) = reader.read(&mut buf) {
                    parser
                        .write()
                        .unwrap_or_else(|e| e.into_inner())
                        .process(&buf[..n]);
                }
            })
        };
        {
            let exit = exit.clone();
            thread::spawn(move || {
                let status = child.wait();
                // Report the end only after the last output is on screen.
                let _ = output.join();
                let code = status.map_or((false, 1), |s| (s.success(), s.exit_code()));
                *exit.lock().unwrap_or_else(|e| e.into_inner()) = Some(code);
            });
        }
        Ok(Self {
            title,
            parser,
            master: pair.master,
            input,
            killer,
            pid,
            exit,
            size: (rows, cols),
        })
    }

    pub fn exit(&self) -> Option<(bool, u32)> {
        *self.exit.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn resize(&mut self, rows: u16, cols: u16) {
        let (rows, cols) = (rows.max(2), cols.max(2));
        if self.size == (rows, cols) {
            return;
        }
        self.size = (rows, cols);
        let _ = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        self.parser
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .screen_mut()
            .set_size(rows, cols);
    }

    /// Runs F on the screen. The parser owns the scroll offset: it moves the offset along as
    /// output arrives, so a view scrolled back stays on the same lines.
    pub fn with_screen<R>(&self, f: impl FnOnce(&vt100::Screen) -> R) -> R {
        f(self
            .parser
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .screen())
    }

    pub fn scrolled(&self) -> usize {
        self.with_screen(vt100::Screen::scrollback)
    }

    pub fn scroll_by(&mut self, lines: isize) {
        let mut parser = self.parser.write().unwrap_or_else(|e| e.into_inner());
        let to = parser.screen().scrollback().saturating_add_signed(lines);
        parser.screen_mut().set_scrollback(to);
    }

    fn send(&mut self, bytes: Vec<u8>) {
        if !bytes.is_empty() {
            self.parser
                .write()
                .unwrap_or_else(|e| e.into_inner())
                .screen_mut()
                .set_scrollback(0);
            let _ = self.input.send(bytes);
        }
    }

    /// Passes a key to the command as the bytes a terminal would send.
    pub fn send_key(&mut self, key: &KeyEvent) {
        let app_cursor = self.with_screen(vt100::Screen::application_cursor);
        self.send(key_bytes(key, app_cursor));
    }

    /// Pasted text, bracketed when the command asked for that, so it isn't run line by line.
    pub fn send_paste(&mut self, text: &str) {
        let bracketed = self.with_screen(vt100::Screen::bracketed_paste);
        let text = text.replace("\r\n", "\r").replace('\n', "\r");
        let bytes = if bracketed {
            format!("\x1b[200~{text}\x1b[201~")
        } else {
            text
        };
        self.send(bytes.into_bytes());
    }

    /// Asks the command to stop: SIGHUP to its process group, as closing a terminal does. A
    /// command running as root through pkexec or sudo ignores this user's signals and keeps
    /// running until it ends or this program exits (which hangs its terminal up).
    pub fn hang_up(&mut self) -> bool {
        let group = self.pid.and_then(|pid| i32::try_from(pid).ok());
        // SAFETY: kill(2) with a negative pid signals that process group; no memory involved.
        let signalled = group.is_some_and(|pgid| unsafe { libc::kill(-pgid, libc::SIGHUP) } == 0);
        signalled | self.killer.kill().is_ok()
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid
    }
}

impl Drop for Pane {
    fn drop(&mut self) {
        if self.exit().is_none() {
            self.hang_up();
        }
    }
}

/// APP_CURSOR is the command's application cursor mode (DECCKM), in which the arrows, Home and
/// End send ESC O x instead of ESC [ x, as less, vim and readline expect.
pub fn key_bytes(key: &KeyEvent, app_cursor: bool) -> Vec<u8> {
    let cursor = |c: u8| {
        if app_cursor {
            vec![0x1b, b'O', c]
        } else {
            vec![0x1b, b'[', c]
        }
    };
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let mut bytes = match key.code {
        KeyCode::Char(c) if ctrl && c.is_ascii_alphabetic() => {
            vec![(c.to_ascii_lowercase() as u8) & 0x1f]
        }
        KeyCode::Char(' ' | '@' | '2') if ctrl => vec![0],
        // crossterm reports the bytes 0x1c-0x1f (Ctrl-\ ] ^ _) as Ctrl-4 to Ctrl-7.
        KeyCode::Char(c @ '4'..='7') if ctrl => vec![c as u8 - b'4' + 0x1c],
        KeyCode::Char(c) => c.to_string().into_bytes(),
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => cursor(b'A'),
        KeyCode::Down => cursor(b'B'),
        KeyCode::Right => cursor(b'C'),
        KeyCode::Left => cursor(b'D'),
        KeyCode::Home => cursor(b'H'),
        KeyCode::End => cursor(b'F'),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::F(n @ 1..=4) => vec![0x1b, b'O', b'P' + n - 1],
        KeyCode::F(n @ 5..=12) => {
            let code = [15, 17, 18, 19, 20, 21, 23, 24][usize::from(n - 5)];
            format!("\x1b[{code}~").into_bytes()
        }
        _ => Vec::new(),
    };
    // Alt sends the key prefixed with ESC, as xterm does by default.
    if key.modifiers.contains(KeyModifiers::ALT) && !bytes.is_empty() {
        bytes.insert(0, 0x1b);
    }
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn wait_exit(pane: &Pane) -> Option<(bool, u32)> {
        let deadline = Instant::now() + Duration::from_secs(10);
        while pane.exit().is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        pane.exit()
    }

    fn argv(script: &str) -> Vec<String> {
        ["sh", "-c", script].map(String::from).into()
    }

    #[test]
    fn keys_become_terminal_bytes() {
        let k = |code, m| key_bytes(&KeyEvent::new(code, m), false);
        assert_eq!(k(KeyCode::Char('c'), KeyModifiers::CONTROL), [3]);
        assert_eq!(k(KeyCode::Char('é'), KeyModifiers::NONE), "é".as_bytes());
        assert_eq!(k(KeyCode::Enter, KeyModifiers::NONE), [b'\r']);
        assert_eq!(k(KeyCode::Up, KeyModifiers::NONE), b"\x1b[A");
        let up = key_bytes(&KeyEvent::new(KeyCode::Up, KeyModifiers::NONE), true);
        assert_eq!(up, b"\x1bOA");
        assert_eq!(k(KeyCode::F(5), KeyModifiers::NONE), b"\x1b[15~");
        assert_eq!(k(KeyCode::F(1), KeyModifiers::NONE), b"\x1bOP");
        assert_eq!(k(KeyCode::Char('b'), KeyModifiers::ALT), b"\x1bb");
        assert_eq!(k(KeyCode::Char('4'), KeyModifiers::CONTROL), [0x1c]);
        assert_eq!(k(KeyCode::Char(' '), KeyModifiers::CONTROL), [0]);
        assert!(k(KeyCode::F(13), KeyModifiers::NONE).is_empty());
    }

    #[test]
    fn runs_a_command_and_reports_its_exit() {
        let script = "printf 'hello\\n'; read x; echo got:$x; exit 3";
        let mut pane = Pane::spawn("t".into(), &argv(script), 10, 40).unwrap();
        pane.send_paste("abc\n");
        assert_eq!(wait_exit(&pane), Some((false, 3)));
        let text = pane.with_screen(|s| s.contents());
        assert!(text.contains("hello") && text.contains("got:abc"), "{text}");
    }

    #[test]
    fn a_scrolled_view_holds_while_output_arrives() {
        let script = "seq 1 100; read x; seq 101 110";
        let mut pane = Pane::spawn("t".into(), &argv(script), 10, 20).unwrap();
        thread::sleep(Duration::from_millis(300));
        pane.scroll_by(20);
        let top = pane.with_screen(|s| s.contents().lines().next().map(String::from));
        // Typing returns to the bottom, so feed the line without send().
        let _ = pane.input.send(b"\r".to_vec());
        thread::sleep(Duration::from_millis(300));
        assert_eq!(
            pane.with_screen(|s| s.contents().lines().next().map(String::from)),
            top
        );
        assert!(pane.scrolled() > 20);
        wait_exit(&pane);
    }

    #[test]
    fn hang_up_stops_a_command_that_ignores_ctrl_c() {
        let mut pane = Pane::spawn("t".into(), &argv("stty -isig; sleep 30"), 5, 20).unwrap();
        thread::sleep(Duration::from_millis(200));
        pane.send_key(&KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
        thread::sleep(Duration::from_millis(300));
        assert_eq!(pane.exit(), None);
        assert!(pane.hang_up());
        assert!(wait_exit(&pane).is_some());
    }
}
