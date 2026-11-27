//! Runs a short command with a deadline, so a hung docker daemon can't freeze the probe.

use std::{
    io::{self, ErrorKind},
    process::{Command, Output, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};

/// How long any one docker or ip call may take.
pub const LIMIT: Duration = Duration::from_secs(5);

/// The command's output, or a TimedOut error after LIMIT (the command is then killed).
pub fn output(cmd: &mut Command) -> io::Result<Output> {
    output_within(cmd, LIMIT)
}

fn output_within(cmd: &mut Command, limit: Duration) -> io::Result<Output> {
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let pid = child.id();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    rx.recv_timeout(limit).unwrap_or_else(|_| {
        // SAFETY: kill(2) on the child's pid. If it ended just now and was reaped, the pid
        // can't have been reused yet in any realistic window, so this signals nothing else.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGKILL);
        }
        Err(io::Error::new(
            ErrorKind::TimedOut,
            format!("no answer within {}", describe(limit)),
        ))
    })
}

/// "5 seconds", "300 ms" or "500 µs", with integers only: float formatting would add about
/// 20 KB to the binary for one message.
fn describe(limit: Duration) -> String {
    let us = limit.as_micros();
    if us.is_multiple_of(1_000_000) {
        format!("{} seconds", us / 1_000_000)
    } else if us.is_multiple_of(1000) {
        format!("{} ms", us / 1000)
    } else {
        format!("{us} µs")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn returns_output_and_times_out() {
        let out = output(Command::new("sh").args(["-c", "echo hi; echo err >&2"])).unwrap();
        assert_eq!(out.stdout, b"hi\n");
        assert_eq!(out.stderr, b"err\n");
        // A short limit, so the test doesn't wait out the real 5 seconds.
        let limit = Duration::from_millis(300);
        let start = Instant::now();
        let err = output_within(Command::new("sleep").arg("30"), limit).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::TimedOut);
        assert_eq!(err.to_string(), "no answer within 300 ms");
        assert_eq!(describe(LIMIT), "5 seconds");
        assert_eq!(describe(Duration::from_micros(500)), "500 µs");
        assert!(start.elapsed() < limit + Duration::from_secs(2));
    }
}
