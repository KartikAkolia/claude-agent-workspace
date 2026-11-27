//! Follows the server's log with `docker logs -f`, restarting the follow whenever it ends (the
//! container stopped or was recreated). The last lines are kept for the log panel.

use crate::cmd;
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader},
    os::unix::process::CommandExt,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

const KEEP: usize = 2000;

#[derive(Default)]
struct Buffer {
    lines: VecDeque<String>,
    /// Lines ever added, and how many times a new follow replaced them, so a view scrolled up
    /// can stay on the same lines while new ones arrive.
    appended: u64,
    generation: u64,
}

/// Where the log panel is scrolled to, in lines up from the newest.
#[derive(Default)]
pub struct LogView {
    pub scroll: usize,
    appended: u64,
    generation: u64,
}

pub struct LogTail {
    buffer: Arc<Mutex<Buffer>>,
    child: Arc<Mutex<Option<Child>>>,
    stop: Arc<AtomicBool>,
}

impl LogTail {
    pub fn start(container: &'static str) -> Self {
        let tail = Self {
            buffer: Arc::default(),
            child: Arc::default(),
            stop: Arc::default(),
        };
        let (buffer, child, stop) = (tail.buffer.clone(), tail.child.clone(), tail.stop.clone());
        thread::spawn(move || {
            // The run last followed. A stopped container's log doesn't change, so it isn't
            // followed again (which would reset a view scrolled up to read why it stopped).
            let mut followed = None;
            while !stop.load(Ordering::Relaxed) {
                if let Some((run, running)) = current_run(container)
                    && (running || followed.as_ref() != Some(&run))
                {
                    follow(container, &buffer, &child, &stop);
                    followed = Some(run);
                }
                for _ in 0..30 {
                    if stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            }
        });
        tail
    }

    /// The lines for a panel of HEIGHT rows. A view scrolled up moves with the lines added since
    /// it was last drawn, so what's on screen stays put; a new follow resets it to the bottom.
    pub fn window(&self, height: usize, view: &mut LogView) -> Vec<String> {
        let buf = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        if buf.generation != view.generation {
            view.scroll = 0;
        } else if view.scroll > 0 {
            view.scroll += (buf.appended - view.appended) as usize;
        }
        (view.appended, view.generation) = (buf.appended, buf.generation);
        view.scroll = view.scroll.min(buf.lines.len().saturating_sub(height));
        let end = buf.lines.len() - view.scroll;
        buf.lines
            .range(end.saturating_sub(height)..end)
            .cloned()
            .collect()
    }
}

/// The container's ID and start time, which name one run, and whether it's running.
fn current_run(container: &str) -> Option<(String, bool)> {
    let out = cmd::output(Command::new("docker").args([
        "inspect",
        "--type",
        "container",
        "-f",
        "{{.Id}} {{.State.StartedAt}} {{.State.Running}}",
        container,
    ]))
    .ok()
    .filter(|o| o.status.success())?;
    let text = String::from_utf8_lossy(&out.stdout);
    let (run, running) = text.trim().rsplit_once(' ')?;
    Some((run.to_string(), running == "true"))
}

fn follow(container: &str, buffer: &Mutex<Buffer>, slot: &Mutex<Option<Child>>, stop: &AtomicBool) {
    let out = {
        // Spawn and store under the lock, so Drop can never miss a child it should kill.
        let mut slot = slot.lock().unwrap_or_else(|e| e.into_inner());
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let mut cmd = Command::new("sh");
        // The server logs to stdout and stderr; one pipe keeps them in order.
        cmd.args([
            "-c",
            "exec docker logs -f --tail 300 \"$1\" 2>&1",
            "sh",
            container,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
        // If this program dies without running Drop (SIGKILL), the follow dies with it rather
        // than lingering on a quiet container. The signal fires when this thread ends, which is
        // only after the follow loop has stopped.
        // SAFETY: prctl is async-signal-safe and touches no memory shared with the parent.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
                Ok(())
            });
        }
        let Ok(mut child) = cmd.spawn() else { return };
        let out = child.stdout.take();
        *slot = Some(child);
        out
    };
    if let Some(out) = out {
        let mut reader = BufReader::new(out);
        let mut raw = Vec::new();
        // A new follow repeats the tail, so the old lines go once it has something to show.
        let mut fresh = true;
        while reader.read_until(b'\n', &mut raw).is_ok_and(|n| n > 0) {
            let line = clean(&String::from_utf8_lossy(&raw));
            raw.clear();
            let mut buf = buffer.lock().unwrap_or_else(|e| e.into_inner());
            if fresh {
                buf.lines.clear();
                buf.generation += 1;
                fresh = false;
            }
            if buf.lines.len() == KEEP {
                buf.lines.pop_front();
            }
            buf.lines.push_back(line);
            buf.appended += 1;
        }
    }
    kill(slot);
}

fn kill(slot: &Mutex<Option<Child>>) {
    if let Some(mut child) = slot.lock().unwrap_or_else(|e| e.into_inner()).take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// Strips terminal escapes, carriage returns and other controls, which would garble a cell.
pub fn clean(line: &str) -> String {
    let mut out = String::new();
    let mut chars = line.trim_end_matches(['\n', '\r']).chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.next() {
                // CSI: parameters, then a final byte in @..~
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC: up to BEL or ESC \
                Some(']') => {
                    while let Some(c) = chars.next() {
                        if c == '\x07' || (c == '\x1b' && chars.next_if_eq(&'\\').is_some()) {
                            break;
                        }
                    }
                }
                // A charset designation such as ESC ( B takes one more character.
                Some('(' | ')' | '*' | '+') => {
                    chars.next();
                }
                _ => {}
            },
            '\t' => out.push_str("    "),
            // A progress line rewrites itself after \r: keep what was written last.
            '\r' => out.clear(),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

impl Drop for LogTail {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        kill(&self.child);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_escapes() {
        assert_eq!(
            clean("\x1b[32m[13:21] INFO\x1b[0m: ok\r\n"),
            "[13:21] INFO: ok"
        );
        assert_eq!(clean("a\tb"), "a    b");
        assert_eq!(clean("\x1b[2~rest"), "rest");
        assert_eq!(clean("\x1b]0;title\x07text\x1b(B!"), "text!");
        assert_eq!(clean("10%\r50%\r100% done"), "100% done");
    }

    fn tail_of(n: u64) -> LogTail {
        let buffer = Buffer {
            lines: (0..n).map(|i| i.to_string()).collect(),
            appended: n,
            generation: 1,
        };
        LogTail {
            buffer: Arc::new(Mutex::new(buffer)),
            child: Arc::default(),
            stop: Arc::new(AtomicBool::new(true)),
        }
    }

    #[test]
    fn window_clamps_and_holds_a_scrolled_view() {
        let tail = tail_of(10);
        let mut view = LogView::default();
        assert_eq!(tail.window(3, &mut view), ["7", "8", "9"]);
        view.scroll = 2;
        assert_eq!(tail.window(3, &mut view), ["5", "6", "7"]);
        // Two new lines arrive: the scrolled view keeps showing the same three.
        {
            let mut buf = tail.buffer.lock().unwrap();
            buf.lines.extend(["10".into(), "11".into()]);
            buf.appended += 2;
        }
        assert_eq!(tail.window(3, &mut view), ["5", "6", "7"]);
        assert_eq!(view.scroll, 4);
        view.scroll = 99;
        assert_eq!(tail.window(3, &mut view), ["0", "1", "2"]);
        tail.buffer.lock().unwrap().generation += 1;
        assert_eq!(tail.window(3, &mut view), ["9", "10", "11"]);
    }
}
