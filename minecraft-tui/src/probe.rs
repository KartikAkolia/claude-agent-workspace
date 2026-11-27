//! Reads the stack's state on a background thread, so a slow docker call never stalls the screen.
//! Everything comes from the docker CLI, ip(8) and a server ping: nothing here needs root.

use crate::{cmd, config, slp};
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc::{self, Receiver, RecvTimeoutError, Sender},
    thread,
    time::Duration,
};

const INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Container {
    pub status: String,
    pub health: String,
    pub restarts: u32,
    pub started_at: String,
    pub finished_at: String,
    pub exit_code: i64,
}

impl Container {
    pub fn running(&self) -> bool {
        self.status == "running"
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// The kernel sends the server's address to the stack's bridge.
    Pinned,
    /// It goes somewhere else, such as a Twingate Client's tunnel (the device is named).
    Elsewhere(String),
    Unknown,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    /// Set when docker itself fails (daemon down, no permission); container fields are then
    /// unknown rather than missing.
    pub docker_error: Option<String>,
    pub installed: bool,
    pub server: Option<Container>,
    pub connector: Option<Container>,
    /// Other running twingate/connector containers, which may serve the same Remote Network.
    pub other_connectors: Vec<String>,
    /// The server's settings as the running container has them (MEMORY, VERSION...).
    pub settings: Vec<(String, String)>,
    pub server_ip: Option<String>,
    pub connector_state: Option<String>,
    pub route: Route,
    pub ping: Option<Result<slp::Status, String>>,
}

impl Snapshot {
    pub fn setting(&self, key: &str) -> &str {
        self.settings
            .iter()
            .find(|(k, _)| k == key)
            .map_or("", |(_, v)| v)
    }

    pub fn server_running(&self) -> bool {
        self.server.as_ref().is_some_and(Container::running)
    }

    pub fn connector_running(&self) -> bool {
        self.connector.as_ref().is_some_and(Container::running)
    }
}

/// The settings shown and edited; the Connector's environment is never read, as it holds tokens.
pub const SETTING_KEYS: [&str; 7] = [
    "VERSION",
    "TYPE",
    "MEMORY",
    "DIFFICULTY",
    "MAX_PLAYERS",
    "MOTD",
    "OPS",
];

/// Status, health, restarts, start and stop times, exit code, and the static address on the
/// stack's own network (set even while stopped). NETWORK is replaced with config::NETWORK.
const STATE_FORMAT: &str = "{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t{{.RestartCount}}\t{{.State.StartedAt}}\t{{.State.FinishedAt}}\t{{.State.ExitCode}}\t{{with index .NetworkSettings.Networks \"NETWORK\"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}";

/// Starts the probe thread. Send () on the returned sender to take a snapshot now.
pub fn spawn(dir: PathBuf) -> (Receiver<Snapshot>, Sender<()>) {
    let (tx, rx) = mpsc::channel();
    let (refresh_tx, refresh_rx) = mpsc::channel::<()>();
    thread::spawn(move || {
        loop {
            if tx.send(take(&dir)).is_err() {
                return;
            }
            match refresh_rx.recv_timeout(INTERVAL) {
                Ok(()) | Err(RecvTimeoutError::Timeout) => while refresh_rx.try_recv().is_ok() {},
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });
    (rx, refresh_tx)
}

enum Inspect {
    Found(String),
    Missing,
    Failed(String),
}

fn inspect(name: &str, format: &str) -> Inspect {
    let out = cmd::output(Command::new("docker").args([
        "inspect",
        "--type",
        "container",
        "-f",
        format,
        name,
    ]));
    match out {
        Err(e) => Inspect::Failed(format!("docker: {e}")),
        Ok(out) if out.status.success() => {
            Inspect::Found(String::from_utf8_lossy(&out.stdout).into_owned())
        }
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            if err.contains("No such") {
                Inspect::Missing
            } else {
                Inspect::Failed(err)
            }
        }
    }
}

pub fn parse_state(line: &str) -> (Container, Option<String>) {
    let mut fields = line.trim_end_matches(['\r', '\n']).split('\t');
    let mut next = || fields.next().unwrap_or("").trim().to_string();
    let container = Container {
        status: next(),
        health: next(),
        restarts: next().parse().unwrap_or(0),
        started_at: next(),
        finished_at: next(),
        exit_code: next().parse().unwrap_or(0),
    };
    let ip = Some(next()).filter(|ip| !ip.is_empty());
    (container, ip)
}

fn parse_settings<'a>(env: impl Iterator<Item = &'a str>) -> Vec<(String, String)> {
    let env: Vec<(&str, &str)> = env.filter_map(|l| l.split_once('=')).collect();
    SETTING_KEYS
        .iter()
        .map(|key| {
            let value = env
                .iter()
                .rev()
                .find(|(k, _)| k == key)
                .map_or("", |(_, v)| *v);
            (key.to_string(), value.to_string())
        })
        .collect()
}

/// The Connector's last "State: X" in its current run: Online, Authentication, Error...
pub fn last_state(log: &str) -> Option<String> {
    log.lines().rev().find_map(|line| {
        let rest = &line[line.find("State: ")? + 7..];
        let word: String = rest.chars().take_while(char::is_ascii_alphabetic).collect();
        Some(word).filter(|w| !w.is_empty())
    })
}

fn connector_state(started_at: &str) -> Option<String> {
    let out = cmd::output(Command::new("docker").args([
        "logs",
        "--since",
        started_at,
        "--tail",
        "500",
        config::CONNECTOR,
    ]))
    .ok()?;
    // The Connector logs to stdout; stderr only counts when stdout has no state at all.
    last_state(&String::from_utf8_lossy(&out.stdout))
        .or_else(|| last_state(&String::from_utf8_lossy(&out.stderr)))
}

/// The device in `ip route get` output: "172.30.0.10 dev mc-twingate0 src ...".
pub fn route_device(out: &str) -> Option<&str> {
    let mut words = out.split_whitespace();
    words.find(|w| *w == "dev")?;
    words.next()
}

/// Asks the kernel which way it would send the server's address, as the replies to it go.
fn route(ip: &str) -> Route {
    let Ok(out) = cmd::output(Command::new("ip").args(["route", "get", ip])) else {
        return Route::Unknown;
    };
    match route_device(&String::from_utf8_lossy(&out.stdout)) {
        Some(dev) if dev == config::BRIDGE => Route::Pinned,
        Some(dev) => Route::Elsewhere(dev.to_string()),
        None => Route::Unknown,
    }
}

fn other_connectors() -> Vec<String> {
    let Ok(out) =
        cmd::output(Command::new("docker").args(["ps", "--format", "{{.Names}}\t{{.Image}}"]))
    else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .filter(|(name, image)| {
            *name != config::CONNECTOR && image.starts_with("twingate/connector")
        })
        .map(|(name, _)| name.to_string())
        .collect()
}

fn take(dir: &Path) -> Snapshot {
    let mut snap = Snapshot {
        docker_error: None,
        installed: dir.join("compose.yaml").is_file(),
        server: None,
        connector: None,
        other_connectors: Vec::new(),
        settings: Vec::new(),
        server_ip: None,
        connector_state: None,
        route: Route::Unknown,
        ping: None,
    };
    let state_format = STATE_FORMAT.replace("NETWORK", config::NETWORK);
    let server_format =
        format!("{state_format}\n{{{{range .Config.Env}}}}{{{{println .}}}}{{{{end}}}}");
    match inspect(config::SERVER, &server_format) {
        Inspect::Found(out) => {
            let mut lines = out.lines();
            let (container, ip) = parse_state(lines.next().unwrap_or(""));
            snap.server = Some(container);
            snap.server_ip = ip;
            snap.settings = parse_settings(lines);
        }
        Inspect::Missing => {}
        Inspect::Failed(e) => {
            snap.docker_error = Some(e);
            return snap;
        }
    }
    match inspect(config::CONNECTOR, &state_format) {
        Inspect::Found(out) => {
            let (container, _) = parse_state(&out);
            if container.running() {
                snap.connector_state = connector_state(&container.started_at);
            }
            snap.connector = Some(container);
        }
        Inspect::Missing => {}
        Inspect::Failed(e) => snap.docker_error = Some(e),
    }
    snap.other_connectors = other_connectors();
    if let Some(ip) = snap.server_ip.clone() {
        snap.route = route(&ip);
        if snap.server_running() {
            snap.ping = Some(slp::ping(&ip, 25565, Duration::from_millis(1500)));
        }
    }
    snap
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_inspect_line() {
        let line =
            "running\thealthy\t3\t2026-11-27T13:29:23Z\t0001-01-01T00:00:00Z\t0\t172.30.0.10\n";
        let (c, ip) = parse_state(line);
        assert!(c.running());
        assert_eq!(c.health, "healthy");
        assert_eq!(c.restarts, 3);
        assert_eq!(ip.as_deref(), Some("172.30.0.10"));
        let (c, ip) = parse_state("exited\tnone\t0\tx\t2026-11-27T13:31:50Z\t137\t");
        assert_eq!((c.status.as_str(), c.exit_code), ("exited", 137));
        assert_eq!(ip, None);
    }

    #[test]
    fn the_template_names_the_stack_network() {
        let f = STATE_FORMAT.replace("NETWORK", config::NETWORK);
        assert!(f.contains("\"minecraft-twingate_minecraft-net\""));
    }

    #[test]
    fn settings_take_the_last_value() {
        let s = parse_settings(["MEMORY=2G", "MOTD=a=b", "MEMORY=4G", "PATH=/bin"].into_iter());
        let get = |k: &str| s.iter().find(|(key, _)| key == k).unwrap().1.clone();
        assert_eq!(get("MEMORY"), "4G");
        assert_eq!(get("MOTD"), "a=b");
        assert_eq!(get("OPS"), "");
        assert_eq!(s.len(), SETTING_KEYS.len());
    }

    #[test]
    fn finds_the_last_connector_state() {
        let log = "x State: Offline\ny State: Authentication\nz State: Online\nnoise\n";
        assert_eq!(last_state(log).as_deref(), Some("Online"));
        assert_eq!(last_state("nothing here"), None);
    }

    #[test]
    fn reads_the_route_device() {
        let out = "172.30.0.10 dev mc-twingate0 src 172.30.0.1 uid 1000 \n    cache \n";
        assert_eq!(route_device(out), Some("mc-twingate0"));
        assert_eq!(
            route_device("172.30.0.10 dev sdwan0 src 100.96.0.2"),
            Some("sdwan0")
        );
        assert_eq!(route_device(""), None);
    }
}
