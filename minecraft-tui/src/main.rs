//! minecraft-tui: a terminal front end for the Minecraft + Twingate stack. It shows the stack's
//! state and runs actions; scripts/minecraft-twingate/minecraft-twingate.sh stays the only thing that configures it.
//! Docs: docs/minecraft-tui.md

mod actions;
mod app;
mod cmd;
mod config;
mod form;
mod logs;
mod pane;
mod probe;
mod slp;
mod ui;

use std::process::ExitCode;

fn main() -> ExitCode {
    let cfg = match config::Config::from_args(std::env::args().skip(1)) {
        Ok(Some(cfg)) => cfg,
        Ok(None) => {
            print!("{}", config::USAGE);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("minecraft-tui: {e}");
            return ExitCode::from(2);
        }
    };
    app::catch_signals();
    match ratatui::run(|terminal| app::App::new(cfg).run(terminal)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("minecraft-tui: {e}");
            ExitCode::FAILURE
        }
    }
}
