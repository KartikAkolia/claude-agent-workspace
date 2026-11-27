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
    rx.recv_timeout(LIMIT).unwrap_or_else(|_| {
        // SAFETY: kill(2) on the child's pid. If it ended just now and was reaped, the pid
        // can't have been reused yet in any realistic window, so this signals nothing else.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGKILL);
        }
        Err(io::Error::new(
            ErrorKind::TimedOut,
            format!("no answer within {} seconds", LIMIT.as_secs()),
        ))
    })
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
        let start = Instant::now();
        let err = output(Command::new("sleep").arg("30")).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::TimedOut);
        assert!(start.elapsed() < LIMIT + Duration::from_secs(2));
    }
}
