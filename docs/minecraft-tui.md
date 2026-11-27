# minecraft-tui: a terminal UI for the Minecraft + Twingate stack

`minecraft-tui/` is a Rust [ratatui](https://ratatui.rs) program that controls the stack `scripts/minecraft-twingate.sh` installs ([minecraft-twingate.md](minecraft-twingate.md)). It shows the server's and the Connector's state live, follows the server log, and runs actions in an embedded terminal pane, the way [linutil](https://github.com/ChrisTitusTech/linutil) runs its scripts. It is only a front end. Anything that changes configuration still goes through the script as root, so the script's validation and safety checks stay the only ones.

## Build and run

Rust 1.88 or newer (edition 2024). Run it as your own user in the `docker` group, not as root.

```sh
cd minecraft-tui
cargo build --release
target/release/minecraft-tui                 # stack in /opt/minecraft-server
target/release/minecraft-tui --dir /srv/mc   # another stack folder
cargo build --profile dist                   # smallest binary, in target/dist/, for handing out
```

`--script PATH` (or `MC_TUI_SCRIPT`) names the `minecraft-twingate.sh` to run for install and update. By default it's this repository's copy, found from the path the binary was built in, so a binary copied elsewhere, or a moved checkout, needs `--script`. The terminal has to be at least 64×18. Below that the screen says so and only `q` or Ctrl-C (quit) work, except while a command runs: it then gets the whole screen and its keys, since it may be asking for a password.

## Screen

The header sums up the server, the Connector and the player count. On the left is the action list. On the right are three panels:

- **Server:** container state and health, when it started (or stopped, with a non-zero exit code), restarts, settings, and from a Server List Ping the version, players and MOTD.
- **Twingate:** the Connector's `State:` from its log, any other running `twingate/connector` containers (which may serve the same Remote Network), the Resource address, which device the kernel routes the server's address to (`via mc-twingate0` is right; anything else, such as `sdwan0`, means the route from [A Twingate Client on the same host](minecraft-twingate.md#a-twingate-client-on-the-same-host) is missing), ping time and the stack folder.
- **Server log:** followed live with `docker logs -f`. Scrolled up, it stays on the same lines while new ones arrive.

The state refreshes every 2 seconds on a background thread, and at once after an action ends. Every `docker` and `ip` call has a 5-second deadline, so a hung daemon shows as an error instead of a frozen screen. When Docker doesn't answer, the containers show as unknown rather than missing, and only Install and Update stay available, since the script starts Docker itself. A stopped server's log isn't followed again until the container starts, so it can be scrolled to read why it stopped.

| Key | Action | Runs |
| --- | --- | --- |
| `s` | Start server | `docker start minecraft-server twingate-connector` |
| `x` | Stop server (asks first) | `docker stop -t 75 minecraft-server`; the Connector stays up |
| `r` | Restart server (asks first) | `docker restart -t 75 minecraft-server` |
| `c` | Server console | `docker exec -it minecraft-server rcon-cli`: `list`, `say`, `op`, `whitelist`...; Ctrl-D leaves |
| `b` | Back up world | see [Backups](#backups) |
| `e` | Edit settings | a form for version, type, heap, difficulty, max players, MOTD and operators, applied by the script's `update` (asks first) |
| `u` | Update stack (asks first) | `minecraft-twingate.sh update` as root |
| `l` | Connector log | `docker logs --tail 200 twingate-connector` |
| `X` | Stop everything (asks first) | `docker stop -t 75` on both containers |
| `i` | Install | `minecraft-twingate.sh install` as root; asks first if already installed |

The arrow keys or `j`/`k` and Enter work too. PgUp/PgDn scroll the server log, End follows it again, and `q` or Ctrl-C quits. Esc only ever cancels. Actions check the state first: Stop on a stopped server, or Start when both containers already run, just says so, and Start and Stop everything leave out a container that doesn't exist. The 75-second stop timeout matches the image, which waits up to 60 seconds for the final world save; Docker's default of 10 could kill the server partway through it.

A confirmation runs only on `y`; Enter or a paste never confirms. After a pane opens, a command ends or a confirmation appears, keys count only once the keyboard has been quiet for 0.7 seconds, longer than the usual auto-repeat delay. Most terminals report a held key as fresh presses, so without this a held Enter could answer `pkexec`'s prompt, close a finished pane and rerun the action, or reach a confirmation. Outside a running command, the up and down arrows, PgUp/PgDn and End never wait, and neither does `q` on the dashboard. A finished command's result also stays up at least 0.4 seconds before a key can close it, so a single key typed ahead can't close it unseen. `n` or Esc on a settings confirmation goes back to the form with the edits kept. The form refuses to empty any field except Operators, because the script reads an empty value as "keep the saved one". Applying settings recreates the server and starts the stack if it's stopped, and the confirmation says so.

Actions run in a pane with a real pseudo-terminal, so `pkexec`'s password prompt, the script's token questions and `rcon-cli` all work there. Keys and pastes go to the command, Ctrl-C interrupts it, and PgUp/PgDn scroll its output. Ctrl-] leaves a command that ignores Ctrl-C or hangs: it hangs the command up (SIGHUP to its process group) and closes the pane. A command running as root through `pkexec` or `sudo` can't be signalled by your user, so it may keep running until it ends; the message says so and gives its pid. Alt combinations, Ctrl with symbols and F1 to F12 reach the command too, and the arrows, Home and End follow the command's application cursor mode, as `less` and readline expect. Ctrl-] also starts the quiet wait, so a key typed right after it doesn't run an action. When a command ends, the border turns green or red with the exit code, and Enter, Esc or `q` closes the pane.

SIGTERM, SIGHUP and SIGINT end the program normally, so the terminal is restored. The `docker logs -f` follower is also set to die with the program even if it's killed outright.

## Backups

`b` writes `~/minecraft-backups/world-<date>.tar.gz`. When the server runs, it first turns autosave off and runs `save-all flush`, and it always turns autosave back on afterwards, also after Ctrl-C or a failure. If that fails, for example because the server stopped meanwhile, it says autosave returns when the server restarts.

The archive is `data/` without the top-level server jar, `libraries/` and `.cache/`, which the image downloads again. Mod and plugin jars in `mods/` and `plugins/` stay: the excludes are anchored, because GNU tar's default lets `data/*.jar` match them too. It's created with `umask 077` because it holds the RCON password (`server.properties`, `.rcon-cli.env`), `ops.json` and `usercache.json`. It's written as `.part` and renamed only when complete, so a failed run leaves nothing behind. GNU tar's "file changed as we read it" (exit 1, usually the live log) counts as a backup with a note; any other tar failure fails it. `.env` is outside `data/` and never archived.

## How it works

Root actions run `pkexec env [MC_*=value...] /bin/sh <script> <command> [flags] --dir <dir>`, or `sudo` the same way when `pkexec` is missing, or with no elevator when the program already runs as root. `pkexec`, `sudo` and `env` are taken from `/usr/bin`, `/bin`, `/usr/sbin` or `/sbin` first, and only then from `PATH`'s absolute entries. `pkexec` and `sudo` both reset the environment, so the form passes `MC_DIFFICULTY`, `MC_MAX_PLAYERS`, `MC_MOTD` and `MC_OPS` through `env(1)`; version, type and heap go as `--version`, `--type` and `--memory`. Only changed fields are passed. The script refuses flag values starting with `-` and validates the rest, so nothing typed in the form can add options or override the `--dir` that comes last.

`.env` is root-only, so the form shows the values the running container has, from `docker inspect`. The Connector's environment, which holds its tokens, is never read. Membership of the `docker` group is root-equivalent anyway: that user can read the tokens with `docker inspect twingate-connector`, so `.env`'s mode 600 doesn't keep them from anyone in the group.

Container control uses `docker` directly. The names `minecraft-server`, `twingate-connector`, `mc-twingate0` and the network `minecraft-twingate_minecraft-net` are fixed in the script and repeated in `src/config.rs`, so a rename has to change both.

Source layout: `config.rs` (options, shared names, the root command), `probe.rs` (the state snapshot), `slp.rs` (Server List Ping, with one deadline for the whole reply), `logs.rs` (log follower), `pane.rs` (the pseudo-terminal pane, with portable-pty, vt100 and tui-term), `actions.rs`, `form.rs`, `app.rs` (event loop) and `ui.rs` (drawing).

## Build time

The crate is tuned to build quickly ([details below](#build-time-measurements)):

- **Dependencies.** ratatui is built without its default features: only the crossterm backend, the layout cache and underline colour. That drops the calendar widget (with the `time` crates) and `ratatui-macros`, which nothing here uses: seven crates, taking the dependencies from 89 to 82. The rest can't be trimmed further without rewriting working code: crossterm's `derive-more` and the two `syn` versions are forced by ratatui's and portable-pty's own dependencies, and portable-pty has no default features to turn off. A hand-written JSON parser in place of `serde_json` was tried and rejected: it saved CPU time but not wall time, for 230 lines of parser to maintain.
- **`release` profile.** Cargo's defaults (crate-local LTO, and 256 codegen units when incremental) plus `incremental = true` and `strip`. The binary is 1.29 MB instead of 1.11 MB. CI never builds incrementally, because rust-cache sets `CARGO_INCREMENTAL=0`, so its release build gets Cargo's non-incremental 16 codegen units. `panic` stays `unwind`, because the background threads and the Drop impls that kill child processes rely on it.
- **`dist` profile.** The old release settings (fat LTO, one codegen unit, not incremental) for the smallest binary, 1,105,928 bytes as before, at the old build time.
- **`dev` profile.** Line tables only for this crate, so backtraces keep file and line, and no debug info for dependencies.
- **Linker.** Unchanged: since Rust 1.90, rustup's toolchains link with the bundled rust-lld on x86_64 Linux, and Arch's packaged rustc links with the system LLD. Forcing GNU ld made a debug relink 0.56 s instead of 0.23 s.
- **Tests.** The `cmd.rs` deadline test uses a 300 ms limit instead of the real 5 seconds, so `cargo test` runs in under a second. Its message is formatted with integers only, since float formatting would add about 20 KB to the binary.

### Build-time measurements

Measured on 2026-11-27 on this laptop (Ryzen 9 7940HS, 8 cores and 16 threads, Rust 1.100.0), each build in a fresh target directory, on an idle machine. The CI rows use 4 cores (`taskset -c 0-3`) with `CARGO_INCREMENTAL=0`, as rust-cache sets it; each was run twice and agreed to within 0.3 s. The `release`, `dist` and previous binaries were also driven against the live stack, and every screen and colour dump was identical.

| Scenario | Before | After |
| --- | ---: | ---: |
| Clean debug build | 6.0 s | 5.5 s |
| Debug rebuild after touching `src/ui.rs` | 0.2 s | 0.2 s |
| Clean release build | 15.5–16.5 s | 7.0–7.5 s |
| Release rebuild after touching `src/ui.rs` | 10.3 s | 0.2 s |
| Clean `cargo clippy --all-targets` | 5.2 s | 4.9–5.3 s |
| `cargo test --no-run` after clippy | 3.8 s | 3.1–3.2 s |
| `cargo test` run time | 5.0 s | 0.8 s |
| Clean `dist` build | (was `release`) | 16.0 s |
| CI `check` job (fmt, clippy, tests), 4 cores | 17 s | 11.3 s |
| CI `build` job (release build), 4 cores | 18.8 s | 10.9 s |
| `dist` build, 4 cores | (was the `build` job) | 18.3 s |

The release binary is 1,286,448 bytes and the `dist` binary 1,105,928, the same as the old release build. On GitHub's runners the dependency cache shortens repeat runs further; each run's summary shows the real times.

## Linting

`cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings` run in `.githooks/pre-commit` whenever a commit adds, changes or deletes anything in `minecraft-tui/`. The `minecraft-tui.yml` workflow runs both plus `cargo test --locked` on Rust 1.100.0, pinned so a new stable clippy lint can't fail an unrelated change; bump it with the local Rust. In parallel it builds the release binary and keeps it for 7 days as an artifact on the run's page, so a pull request's build can be downloaded: a `.tar.gz` holding the binary for x86_64 Linux with Ubuntu's glibc or newer. Its default `--script` points into the runner's checkout, so pass `--script` or set `MC_TUI_SCRIPT` when running it. Download it from the run's page in a browser, or with `gh api repos/KartikAkolia/claude-agent-workspace/actions/artifacts/<id>/zip > minecraft-tui.tar.gz` (the id is in `gh api .../actions/runs/<run>/artifacts`): `gh run download` expects every artifact to be a zip and fails on this one with "not a valid zip file". Each run's summary lists how long each build step took. The workflow's design is in [repo-tooling.md](repo-tooling.md#ci-workflows).

## Validation

Checked on 2026-11-27 with ratatui 0.30.2, tui-term 0.3.4, vt100 0.16.2, portable-pty 0.9.0 and libc 0.2 on Rust 1.100, against the live stack on this laptop (hostname `archlinux`), with the server stopped and the Connector online.

- `cargo fmt --check` and clippy are clean, and `cargo test` passes 23 unit tests. They include real commands in the pane (exit codes, a scrolled view holding still, Ctrl-] hanging up a command that turned off Ctrl-C), a ping deadline against a silent server, and the log view anchoring.
- Four skeptic agents reviewed the first version: one for the pane and its processes, one for root commands and safety, one for the accuracy of the probe, and one driving the real program in a pseudo-terminal at sizes from 140×40 down to 20×5. Their findings were fixed, and a second run of the same key sequences confirmed the fixes on the live stack: "already stopped" for Stop on a stopped server, "Stopped" with the stop time, the extra Connector listed, an emptied heap refused, Esc never quitting, an early Enter not closing a finished pane, the too-small notice, and the confirmation's keys in its border at 64×18.
- A high-effort code review then found a held key getting past the confirmations (crossterm only reports auto-repeat under the kitty keyboard protocol), the backup's `*.jar` exclude dropping mod jars, the stopped server's log jumping back to the bottom, and docker calls with no deadline. All are fixed, and so are the second pass's findings (a key arriving in the same loop as a command's end could close its pane, `q` on the too-small screen quit in the middle of a command, and the hook's handling of a deleted crate). Re-run live: 40 Enters 30 ms apart left a finished pane open, one Enter after a pause closed it without rerunning the action, and a scrolled stopped log stayed put past the 3-second follow check.
- SIGTERM to the program exits 0 with the terminal restored.
- Backup, run through the pane with `HOME` pointed at a scratch folder and the server stopped, wrote an 8.1 MB archive with mode 600, `data/` without the jar, `libraries/` or `.cache/`.

Not yet tested: Start, Stop, Restart, Update and Install against the live stack, which the skeptic runs were barred from; Backup and the console with the server running; and a root command through `pkexec` in the pane.
