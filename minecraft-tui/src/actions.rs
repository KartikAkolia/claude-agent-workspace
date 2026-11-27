//! What each menu entry runs. Container control goes straight to docker (the docker group is
//! enough); anything that changes configuration goes through minecraft-twingate.sh as root,
//! so its validation and safety checks stay the only ones.

use crate::{
    config::{self, Config},
    probe::Snapshot,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Start,
    Stop,
    Restart,
    Console,
    Backup,
    Settings,
    Update,
    ConnectorLog,
    StopAll,
    Install,
}

pub const ACTIONS: [Action; 10] = [
    Action::Start,
    Action::Stop,
    Action::Restart,
    Action::Console,
    Action::Backup,
    Action::Settings,
    Action::Update,
    Action::ConnectorLog,
    Action::StopAll,
    Action::Install,
];

impl Action {
    pub fn key(self) -> char {
        match self {
            Self::Start => 's',
            Self::Stop => 'x',
            Self::Restart => 'r',
            Self::Console => 'c',
            Self::Backup => 'b',
            Self::Settings => 'e',
            Self::Update => 'u',
            Self::ConnectorLog => 'l',
            Self::StopAll => 'X',
            Self::Install => 'i',
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Start => "Start server",
            Self::Stop => "Stop server",
            Self::Restart => "Restart server",
            Self::Console => "Server console",
            Self::Backup => "Back up world",
            Self::Settings => "Edit settings",
            Self::Update => "Update stack",
            Self::ConnectorLog => "Connector log",
            Self::StopAll => "Stop everything",
            Self::Install => "Install",
        }
    }

    pub fn help(self) -> &'static str {
        match self {
            Self::Start => "Start the server and the Twingate Connector",
            Self::Stop => "Stop the server; the Connector stays online",
            Self::Restart => "Restart the server",
            Self::Console => "rcon-cli: list, say, op, whitelist... Ctrl-D leaves",
            Self::Backup => "Save the world and archive it to ~/minecraft-backups",
            Self::Settings => "Version, heap, difficulty, MOTD... applied as root",
            Self::Update => "Pull newer images, recreate the stack (root)",
            Self::ConnectorLog => "The Twingate Connector's last 200 log lines",
            Self::StopAll => "Stop the server and the Connector",
            Self::Install => "The script's install: Docker, config, tokens (root)",
        }
    }
}

pub struct Plan {
    pub title: String,
    pub argv: Vec<String>,
    pub confirm: Option<String>,
}

pub enum Next {
    Run(Plan),
    OpenForm,
    Message(String),
}

fn docker(title: &str, args: &[&str], confirm: Option<&str>) -> Next {
    let mut argv = vec!["docker".to_string()];
    argv.extend(args.iter().map(|a| a.to_string()));
    Next::Run(Plan {
        title: title.into(),
        argv,
        confirm: confirm.map(String::from),
    })
}

/// Saves the world first when the server runs and always turns saving back on. The archive is
/// private (it holds the RCON password) and only appears once complete. The server jar (top
/// level only: mods/ and plugins/ jars stay), libraries and caches are left out, as the image
/// downloads them again. --anchored and --no-wildcards-match-slash keep data/*.jar from
/// matching data/mods/x.jar, as GNU tar's default would.
const BACKUP: &str = r#"set -eu
umask 077
dir=$1 dest=$HOME/minecraft-backups
mkdir -p "$dest"
file=$dest/world-$(date +%Y%m%d-%H%M%S).tar.gz
part=$file.part
saving_off=false
finish() {
	rc=$?
	rm -f "$part"
	if [ "$saving_off" = true ] && ! docker exec minecraft-server rcon-cli save-on >/dev/null; then
		echo "Could not turn saving back on; it comes back when the server restarts." >&2
	fi
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT HUP TERM
if [ "$(docker inspect -f '{{.State.Running}}' minecraft-server 2>/dev/null)" = true ]; then
	saving_off=true
	docker exec minecraft-server rcon-cli save-off
	docker exec minecraft-server rcon-cli save-all flush
fi
echo "Writing $file"
# GNU tar exits 1 when a file changed while it was read, such as the live log: still a backup.
rc=0
tar -C "$dir" -czf "$part" --anchored --no-wildcards-match-slash \
	--exclude='data/libraries' --exclude='data/.cache' --exclude='data/*.jar' data || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
[ "$rc" -eq 0 ] || echo "Some files changed while being archived (logs, usually)."
mv "$part" "$file"
echo "Saved $file ($(du -h "$file" | cut -f1))"
"#;

pub fn next(action: Action, cfg: &Config, snap: Option<&Snapshot>) -> Next {
    let Some(snap) = snap else {
        return Next::Message("Still reading the stack's state; try again in a moment.".into());
    };
    let has_server = snap.server.is_some();
    let (running, connector) = (snap.server_running(), snap.connector_running());
    let needs_server = matches!(
        action,
        Action::Start
            | Action::Stop
            | Action::Restart
            | Action::Console
            | Action::StopAll
            | Action::Settings
    );
    // The script's install and update start Docker themselves, so only they still make sense.
    let starts_docker = action == Action::Install || (action == Action::Update && snap.installed);
    if snap.docker_error.is_some() && !starts_docker {
        return Next::Message(
            "Docker isn't answering, so nothing can run (see the Server panel).".into(),
        );
    }
    if needs_server && !has_server {
        return Next::Message(
            "There is no minecraft-server container yet: run Install (i).".into(),
        );
    }
    let root = |title: &str, args: &[&str], confirm: Option<String>| {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        match cfg.root_command(&args, &[]) {
            Ok(argv) => Next::Run(Plan {
                title: title.into(),
                argv,
                confirm,
            }),
            Err(e) => Next::Message(e),
        }
    };
    let stop = ["stop", "-t", config::STOP_TIMEOUT];
    // Start and Stop everything name only containers that exist, or docker fails the lot.
    let mut present = vec![config::SERVER];
    if snap.connector.is_some() {
        present.push(config::CONNECTOR);
    }
    match action {
        Action::Start if running && connector => Next::Message("Both are already running.".into()),
        Action::Start => docker("Start", &[&["start"], &present[..]].concat(), None),
        Action::Stop if !running => Next::Message("The server is already stopped.".into()),
        Action::Stop => docker(
            "Stop server",
            &[&stop[..], &[config::SERVER]].concat(),
            Some("Stop the Minecraft server? Players are disconnected."),
        ),
        Action::Restart if !running => {
            Next::Message("The server isn't running: use Start (s).".into())
        }
        Action::Restart => docker(
            "Restart server",
            &["restart", "-t", config::STOP_TIMEOUT, config::SERVER],
            Some("Restart the Minecraft server? Players are disconnected."),
        ),
        Action::Console if !running => {
            Next::Message("The server isn't running: start it first (s).".into())
        }
        Action::Console => {
            docker("Server console", &["exec", "-it", config::SERVER, "rcon-cli"], None)
        }
        Action::ConnectorLog if snap.connector.is_none() => {
            Next::Message("There is no twingate-connector container.".into())
        }
        Action::ConnectorLog => {
            docker("Connector log", &["logs", "--tail", "200", config::CONNECTOR], None)
        }
        Action::StopAll if !running && !connector => {
            Next::Message("Both are already stopped.".into())
        }
        Action::StopAll => docker(
            "Stop everything",
            &[&stop[..], &present[..]].concat(),
            Some("Stop the server and the Twingate Connector? Nobody can reach the server until you start them again."),
        ),
        Action::Backup => Next::Run(Plan {
            title: "Back up world".into(),
            argv: vec![
                "sh".into(),
                "-c".into(),
                BACKUP.into(),
                "sh".into(),
                cfg.dir.display().to_string(),
            ],
            confirm: None,
        }),
        Action::Settings => Next::OpenForm,
        Action::Update if !snap.installed => {
            Next::Message(format!("Nothing installed in {}: run Install (i).", cfg.dir.display()))
        }
        Action::Update => root(
            "Update stack",
            &["update"],
            Some("Run minecraft-twingate.sh update as root? It pulls newer images, recreates changed containers and starts the stack if it's stopped.".into()),
        ),
        Action::Install => root(
            "Install",
            &["install"],
            snap.installed
                .then(|| "The stack is already installed. Run install again anyway?".into()),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::probe::{Container, Route};
    use std::collections::HashSet;

    fn snap(server: Option<&str>, connector: Option<&str>) -> Snapshot {
        let c = |s: &str| Container {
            status: s.into(),
            ..Default::default()
        };
        Snapshot {
            docker_error: None,
            installed: true,
            server: server.map(c),
            connector: connector.map(c),
            other_connectors: Vec::new(),
            settings: Vec::new(),
            server_ip: None,
            connector_state: None,
            route: Route::Unknown,
            ping: None,
        }
    }

    fn cfg() -> Config {
        Config {
            dir: "/opt/mc".into(),
            script: "/bin/sh".into(),
        }
    }

    fn runs(action: Action, s: &Snapshot) -> Option<Vec<String>> {
        match next(action, &cfg(), Some(s)) {
            Next::Run(plan) => Some(plan.argv),
            _ => None,
        }
    }

    #[test]
    fn hotkeys_are_unique_and_not_quit() {
        let keys: HashSet<char> = ACTIONS.iter().map(|a| a.key()).collect();
        assert_eq!(keys.len(), ACTIONS.len());
        assert!(!keys.contains(&'q'));
    }

    #[test]
    fn actions_follow_the_current_state() {
        assert!(matches!(next(Action::Stop, &cfg(), None), Next::Message(_)));
        let none = snap(None, None);
        assert!(runs(Action::Stop, &none).is_none());
        let stopped = snap(Some("exited"), Some("running"));
        assert!(runs(Action::Stop, &stopped).is_none());
        assert!(runs(Action::Restart, &stopped).is_none());
        assert!(runs(Action::Console, &stopped).is_none());
        assert!(runs(Action::Start, &stopped).is_some());
        let up = snap(Some("running"), Some("running"));
        assert!(runs(Action::Start, &up).is_none());
        let only_server = snap(Some("exited"), None);
        assert_eq!(
            runs(Action::Start, &only_server).unwrap(),
            ["docker", "start", "minecraft-server"]
        );
        let stop = runs(Action::Stop, &up).unwrap();
        assert_eq!(stop, ["docker", "stop", "-t", "75", "minecraft-server"]);
        assert!(runs(Action::Backup, &none).is_some());
        let mut down = up.clone();
        down.docker_error = Some("no daemon".into());
        assert!(runs(Action::Start, &down).is_none());
        assert!(
            runs(Action::Update, &down).is_some(),
            "update starts Docker itself"
        );
    }
}
