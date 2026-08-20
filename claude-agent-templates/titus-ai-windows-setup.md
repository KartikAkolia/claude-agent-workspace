# titus-ai on Windows 11 Pro: What It Is and How to Install It

## What this repo actually is

titus-ai is a portable configuration and reusable-skill library for OpenAI's Codex CLI, not a Claude Code repo. CLAUDE.md is only a two-line router pointing at AGENTS.md plus some RTK usage notes, it's not a parallel Claude setup. Mechanically it's dotfiles-style: an installer that symlinks files into `~/.codex` and `~/.agents/skills`. In substance it's a skill library: global Codex instructions, rules, local-model profiles, an opt-in plugin manifest, and thirteen named skills (including `ai-project-manager` and `pr-readiness`) meant to be linked into every repo you work in, not just this one. It deliberately keeps credentials, sessions, caches, and plugin state out of version control.

## What README.md says to install

The installer itself installs nothing. It only symlinks config and skill files already in the repo. Tools it references, but doesn't install:

Codex CLI, assumed already present, required for the plugin flags and `codex review --uncommitted`. Codex plugins, optional, added via `codex plugin add`: `superpowers@openai-curated` is the only one preselected in `codex-plugins.txt`; the README also recommends but doesn't automate a GitHub plugin, a Codex Security plugin, and a Sentry plugin. MCP servers, manual and not installed by this repo: Context7, Playwright or Chrome DevTools. RTK, a Rust CLI, via `cargo install --git https://github.com/rtk-ai/rtk`, which needs Cargo already present. Optional local model tooling: Ollama (`ollama pull qwen3-coder`) and llama.cpp (`llama-server`).

Claude Code itself is never mentioned as something this repo installs or configures.

## install.sh vs install.ps1: is the PowerShell script actually Windows-native?

Worth correcting upfront: install.sh isn't Fedora or dnf specific. It never calls a package manager at all, it's generic POSIX bash (mkdir, ln -s, mv, awk, find, mktemp) that runs on any Linux or macOS with Bash.

install.ps1 is genuinely native Windows PowerShell, already usable as-is on Windows 11 Pro. It's not a WSL script in disguise. It uses `$env:USERPROFILE` and `[Environment]::GetFolderPath(...)` with Windows path separators throughout. The README states CI runs the PowerShell installer on real Windows GitHub Actions runners, not WSL. SPEC.md scopes it explicitly: "The PowerShell installer targets supported Windows PowerShell environments capable of creating symbolic links." There's no apt, dnf, or bash call anywhere in the file.

Two Windows-specific things worth knowing before running it. First, symlink creation needs privilege: `New-Item -ItemType SymbolicLink` requires either Windows Developer Mode enabled or an elevated (Administrator) PowerShell session. The script doesn't auto-elevate, it throws a caught error telling you to enable Developer Mode or run as Administrator. Second, it likely needs PowerShell 7+ (pwsh), not the Windows PowerShell 5.1 that ships by default: it reads `.LinkType` and `.Target` off `Get-Item` results to detect existing symlinks, and those FileSystemInfo properties were added in PowerShell 6.2+. Run it with `pwsh`, not `powershell`.

Like install.sh, it installs no packages via winget or anything else, it only symlinks repo files and, with `-Plugins`, shells out to an already-installed `codex` binary.

## The skill-library convention (SKILLS.md, WORKFLOW.md, CODEX_LAYOUT.md)

This is additive to the single-repo AGENTS.md pattern from the earlier four repos. Instead of one repo carrying its own AGENTS.md/SPEC.md/etc., titus-ai centralizes reusable, cross-repo workflows as skills (`.agents/skills/<name>/SKILL.md`, YAML front matter with name and description, optional `agents/openai.yaml`, references, scripts) that Codex auto-discovers at both repo scope (walking up to the repo root) and user scope (`~/.agents/skills/`, populated by this repo's installer). CODEX_LAYOUT.md documents Codex's real auto-discovery table: AGENTS.md, config.toml, skills, and rules only, nothing under `docs/` is read automatically. WORKFLOW.md stitches the per-repo planning docs and the portable skills into one lifecycle: install, inspect repo, write AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md, `ai-project-manager` plans a phase, user approval gate, implement, `pr-readiness` runs `codex review --uncommitted` to a clean loop, CI and security checks, merge.

The four repos analyzed earlier each show one instantiated version of that convention. titus-ai is the portable engine that generates and enforces it everywhere.

## The ai-project-manager skill

Per its SKILL.md, it's a reusable workflow, not project content: it locates or creates AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md, builds a phase plan mapped to acceptance criteria, stops at approval checkpoints, executes one reviewable phase at a time, and hands off to `pr-readiness` before merge. Its safety rules forbid marking work done without validation, ignoring doc-versus-code conflicts, or crossing an approval checkpoint without sign-off.

The bundled `assets/project-docs/` templates are blank scaffolds, not filled examples, using the same section structure as titus-ai's own real SPEC.md/ROADMAP.md/TASKS.md, but every field is a generic instruction like "Describe the project, its users, and the outcome it provides." Notably, the template AGENTS.md (Purpose, Architecture, Working boundaries, Commands, Validation, Documentation routing) is leaner and more generic than titus-ai's own root AGENTS.md, which adds Operating principles, Command execution, and Before/During editing rules. Same convention already covered, packaged here as a fill-in-the-blank template rather than a repo-specific instance. The README says explicitly to adapt them to the project instead of leaving placeholder requirements.

## Action plan: Windows 11 Pro with winget

Nothing in the repo uses winget. Every package ID below is inferred, not read from the files, so verify before running.

1. `winget install --id Microsoft.PowerShell -e`, to get pwsh 7 (install.ps1 likely needs it, see above).
2. Enable Developer Mode (Settings, Privacy & Security, For developers) so symlink creation succeeds without elevation. This is a manual step the script can't do for you.
3. `winget install --id Git.Git -e`, needed for the `~/github` worktree-discovery walk.
4. Install Codex CLI itself. Not covered by this repo and not winget-confirmed here, check OpenAI's own install docs; it's commonly distributed via npm.
5. From the repo root in `pwsh`: `.\scripts\install.ps1 -DryRun`, review the output, then `.\scripts\install.ps1` (add `-Plugins` once Codex is installed if you want `superpowers@openai-curated`).
6. Optional RTK: `winget install --id Rustlang.Rustup -e`, then `cargo install --git https://github.com/rtk-ai/rtk`, and add `%USERPROFILE%\.cargo\bin` to PATH via `setx` or System Properties, there's no `export` on Windows.
7. Optional local models: Ollama has a real native Windows installer, `winget install --id Ollama.Ollama -e` (inferred ID). llama.cpp has no reliable winget package, plan to grab prebuilt Windows binaries from its GitHub releases manually.
8. Optional GitHub plugin support: `winget install --id GitHub.cli -e` for `gh`.
9. No step here has zero Windows equivalent. The installer is already native. The only real failure mode is an org policy blocking both Developer Mode and elevation, in which case symlinking won't work until that's resolved.
