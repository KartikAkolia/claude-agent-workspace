//! Command-line options, and the names this front end shares with scripts/minecraft-twingate/minecraft-twingate.sh.

use std::{
    env, fs,
    path::{Path, PathBuf},
};

/// Fixed in minecraft-twingate.sh: one stack per host, so the names never vary.
pub const SERVER: &str = "minecraft-server";
pub const CONNECTOR: &str = "twingate-connector";
/// The script's MC_BRIDGE, the bridge its route pins the server's address to.
pub const BRIDGE: &str = "mc-twingate0";
/// The Compose network (project minecraft-twingate, network minecraft-net) holding the server.
pub const NETWORK: &str = "minecraft-twingate_minecraft-net";
/// itzg's wrapper waits up to 60 seconds for the final world save; Docker's default 10 would
/// kill the server in the middle of it.
pub const STOP_TIMEOUT: &str = "75";
pub const DEFAULT_DIR: &str = "/opt/minecraft-server";

pub const USAGE: &str = "\
Usage: minecraft-tui [--dir /opt/minecraft-server] [--script PATH]

A terminal front end for the stack scripts/minecraft-twingate/minecraft-twingate.sh installs.
  --dir     the stack folder (the script's --dir), default /opt/minecraft-server
  --script  minecraft-twingate.sh to run for install and update; default
            $MC_TUI_SCRIPT, else the copy in this repository
Run it as your own user in the docker group; install and update ask for root
through pkexec (or sudo). Docs: docs/minecraft-tui.md
";

pub struct Config {
    pub dir: PathBuf,
    pub script: PathBuf,
}

impl Config {
    /// Ok(None) means --help was asked for.
    pub fn from_args(mut args: impl Iterator<Item = String>) -> Result<Option<Self>, String> {
        let mut dir = PathBuf::from(DEFAULT_DIR);
        let mut script = env::var_os("MC_TUI_SCRIPT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../scripts/minecraft-twingate/minecraft-twingate.sh")
            });
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => return Ok(None),
                "--dir" | "--script" => {
                    let value = args
                        .next()
                        .filter(|v| !v.is_empty())
                        .ok_or(format!("{arg} needs a value"))?;
                    if arg == "--dir" {
                        dir = PathBuf::from(value);
                    } else {
                        script = PathBuf::from(value);
                    }
                }
                other => return Err(format!("unknown option {other} (try --help)")),
            }
        }
        if !dir.is_absolute() {
            return Err(format!("--dir must be an absolute path: {}", dir.display()));
        }
        // pkexec wants an absolute program path, and a clean one reads better in the pane title.
        let script = fs::canonicalize(&script).unwrap_or(script);
        Ok(Some(Self { dir, script }))
    }

    /// The argv that runs minecraft-twingate.sh as root with ARGS and the ENV settings.
    /// pkexec and sudo both drop the caller's environment, so settings go through env(1).
    pub fn root_command(
        &self,
        args: &[String],
        env: &[(String, String)],
    ) -> Result<Vec<String>, String> {
        if !self.script.is_file() {
            return Err(format!(
                "minecraft-twingate.sh not found at {}: pass --script or set MC_TUI_SCRIPT",
                self.script.display()
            ));
        }
        let mut argv = Vec::new();
        if !is_root() {
            let elevator = ["pkexec", "sudo"]
                .into_iter()
                .find_map(tool)
                .ok_or("neither pkexec nor sudo is installed, so root actions can't run")?;
            argv.push(elevator.display().to_string());
        }
        argv.push(tool("env").map_or("/usr/bin/env".into(), |p| p.display().to_string()));
        argv.extend(env.iter().map(|(k, v)| format!("{k}={v}")));
        // Through sh, so the script needn't be executable.
        argv.push("/bin/sh".into());
        argv.push(self.script.display().to_string());
        argv.extend(args.iter().cloned());
        argv.push("--dir".into());
        argv.push(self.dir.display().to_string());
        Ok(argv)
    }
}

/// Effective UID 0, read from /proc so no libc binding is needed.
fn is_root() -> bool {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|l| l.strip_prefix("Uid:"))
                .and_then(|ids| ids.split_whitespace().nth(1).map(|e| e == "0"))
        })
        .unwrap_or(false)
}

/// A root-owned system copy of NAME first, so a planted pkexec earlier on PATH isn't the one
/// handed the password; then PATH's absolute entries.
fn tool(name: &str) -> Option<PathBuf> {
    ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .iter()
        .map(|dir| Path::new(dir).join(name))
        .find(|p| p.is_file())
        .or_else(|| {
            env::split_paths(&env::var_os("PATH")?)
                .filter(|dir| dir.is_absolute())
                .map(|dir| dir.join(name))
                .find(|p| p.is_file())
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Option<Config>, String> {
        Config::from_args(args.iter().map(|s| s.to_string()))
    }

    #[test]
    fn flags_and_errors() {
        let cfg = parse(&["--dir", "/srv/mc", "--script", "/nonexistent/x.sh"])
            .unwrap()
            .unwrap();
        assert_eq!(cfg.dir, PathBuf::from("/srv/mc"));
        assert_eq!(cfg.script, PathBuf::from("/nonexistent/x.sh"));
        assert!(parse(&["--help"]).unwrap().is_none());
        assert!(parse(&["--dir"]).is_err());
        assert!(parse(&["--dir", "relative"]).is_err());
        assert!(parse(&["--bogus"]).is_err());
    }

    #[test]
    fn root_command_passes_settings_through_env() {
        let cfg = Config {
            dir: "/opt/mc".into(),
            script: PathBuf::from("/bin/sh"),
        };
        let argv = cfg
            .root_command(&["update".into()], &[("MC_MOTD".into(), "Hi there".into())])
            .unwrap();
        let tail: Vec<&str> = argv.iter().map(String::as_str).rev().take(6).collect();
        assert_eq!(
            tail,
            [
                "/opt/mc",
                "--dir",
                "update",
                "/bin/sh",
                "/bin/sh",
                "MC_MOTD=Hi there"
            ]
        );
        let missing = Config {
            dir: "/opt/mc".into(),
            script: "/nonexistent/x.sh".into(),
        };
        assert!(missing.root_command(&[], &[]).is_err());
    }
}
