Environment is Git Bash on Windows (MSYS2), not cmd.exe or PowerShell — POSIX syntax works, but native Windows CLI utilities behave differently here:
- `tasklist` needs double-slash flags, e.g. `tasklist //FI "IMAGENAME eq foo.exe" //FO CSV` — a single `/FI` gets parsed as a path and fails with "Invalid argument/option".
- `wmic` is not available in this Git Bash — use `tasklist //FI ...` for process lookups instead.

Package installs: winget preferred — `winget install <Id>`, `winget list --id <Id>` to check what's present.

No test/lint/build commands exist for this project — see `mem:task_completion` for what "done" means instead.

Headroom CLI quirks:
- `headroom doctor` exits with code 1 even at 0 failures (only warnings) — check the printed "N failure(s), M warning(s)" line, not the shell exit code.
- `headroom learn` takes no `--verbosity` flag; run bare for a dry run, add `--apply` to write changes.
- `headroom config` is not a valid subcommand.