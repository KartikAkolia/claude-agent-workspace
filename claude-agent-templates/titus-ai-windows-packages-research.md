# Windows Package Research: Setting Up titus-ai's Pattern with Claude Code

Sourced per your research standards: official/primary sources only, cross-checked, provenance documented below. Where a package exists only in community-maintained listings rather than a project's own docs, that's flagged rather than presented as confirmed.

## Confirmed from official sources

**Claude Code CLI itself.** Anthropic's own docs (code.claude.com/docs/en/setup) document a native winget package:

```
winget install Anthropic.ClaudeCode
```

No admin rights required. Winget installs don't auto-update by default; run `winget upgrade Anthropic.ClaudeCode` periodically, or set `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=1` to have Claude Code run that upgrade for you in the background. The same docs also document a native installer that does auto-update:

```
irm https://claude.ai/install.ps1 | iex
```

Both are officially supported; winget is easier to script into a repeatable setup, the native installer keeps itself current without you remembering to run upgrades.

Git for Windows is called out as optional but recommended: without it, Claude Code falls back to the PowerShell tool for shell commands; with it installed, Claude Code uses Git Bash. Since you're already going to need Git for the ChrisTitusTech repos, install it anyway.

**PowerShell 7.** Microsoft's own docs (learn.microsoft.com) give:

```
winget install --id Microsoft.PowerShell --source winget
```

This is the one titus-ai's `install.ps1` actually needs, not Claude Code. Claude Code itself runs fine on PowerShell 7, CMD, or Bash, per its own system requirements. PowerShell 7 matters here specifically because titus-ai's installer reads `.LinkType`/`.Target` FileSystemInfo properties that only exist from PowerShell 6.2 onward, so run it with `pwsh`, not the Windows-11-default 5.1.

**Git.** git-scm.com's own install page documents:

```
winget install --id Git.Git -e --source winget
```

**GitHub CLI.** The `cli/cli` project's own Windows install docs document:

```
winget install --id GitHub.cli --source winget
```

Note from that doc: the installer modifies PATH, so reopen your terminal window afterward if you're using Windows Terminal.

## Not confirmed in official docs, exists in community winget listings only

**Rust / rustup.** The `Rustlang.Rustup` package (needed for titus-ai's optional RTK tool) shows up on winget aggregator sites, but rustup's own official documentation (rust-lang.github.io/rustup) doesn't mention winget at all as an install path, it only documents `rustup-init.exe` from rustup.rs. This isn't necessarily wrong, winget-pkgs is community-maintained and lots of legitimate packages live there without the upstream project endorsing winget specifically, but it means I can't verify the package ID against the project's own word the way I could for the others above. Before relying on it: run `winget search Rustlang.Rustup` locally to confirm the package still resolves, or just use the official `rustup-init.exe` route to skip the question entirely.

**Ollama.** Same situation. `Ollama.Ollama` appears on third-party winget listing sites, but Ollama's own Windows docs (docs.ollama.com/windows) recommend `OllamaSetup.exe` as "the easiest way to install Ollama on Windows" and don't mention winget. Treat the winget package as unverified against upstream; `winget search Ollama.Ollama` before you script around it, or use the official installer.

## What titus-ai itself does and doesn't install

Worth restating from the earlier repo analysis: titus-ai's `install.ps1` installs no packages at all, it only symlinks the repo's own config and skill files into `~/.codex` and `~/.agents/skills`. Everything above (PowerShell, Git, Rust, Ollama, GitHub CLI) is infrastructure titus-ai *assumes* is already present, not something its installer sets up for you. titus-ai is also built around OpenAI's Codex CLI, not Claude Code, so if the goal is Claude-Code-native use of the same AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md pattern, the templates already delivered to your `claude-agent-templates` folder are the more direct route than running titus-ai's installer itself.

## Your current Cowork setup (session state, not researched)

This part isn't from external sources, it's what's already configured in this Cowork session, for cross-reference against the above:

Plugins installed: Engineering (architecture, code review, documentation, tech-debt, testing-strategy, and more) and Productivity (task management, memory, this dashboard). Plugin Management is also installed as a baseline.

Connectors: Gmail is connected and live in this chat. Google Calendar and Microsoft 365 (SharePoint/OneDrive/Outlook/Teams) are both set up at the account level but switched off for this specific chat, enable them in connector settings to use them here. Notion, Linear, Atlassian Rovo (Jira/Confluence), Slack, Asana, monday.com, ClickUp, PagerDuty, and Datadog are available but not yet connected at all.

None of this bears on the Windows/titus-ai install question above, it's Cowork-side tooling, separate from what runs in your local Claude Code CLI. Listed here only because the task asked for it explicitly.

## Suggested install order

1. `winget install --id Git.Git -e --source winget`
2. `winget install Anthropic.ClaudeCode`
3. `winget install --id Microsoft.PowerShell --source winget` (only if you're going to run titus-ai's own installer)
4. Enable Windows Developer Mode, or plan to run step 5 elevated (needed only for titus-ai's symlink-based installer, not for Claude Code)
5. `pwsh .\scripts\install.ps1 -DryRun` from the titus-ai repo, review, then run for real
6. Optional: `winget install --id GitHub.cli --source winget`
7. Optional, unverified against upstream: Rust via rustup.rs's own installer (not winget), then RTK
8. Optional, unverified against upstream: Ollama via its own OllamaSetup.exe (not winget)

## Sources

- [Set up Claude Code](https://code.claude.com/docs/en/setup) — Anthropic, official docs, winget package, native installer, Windows-specific setup section
- [Install PowerShell 7 on Windows](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6) — Microsoft Learn, official docs
- [Git - Install for Windows](https://git-scm.com/install/windows) — git-scm.com, official project docs
- [cli/cli install_windows.md](https://github.com/cli/cli/blob/trunk/docs/install_windows.md) — GitHub CLI project's own documentation
- [Rustup installation, Windows](https://rust-lang.github.io/rustup/installation/windows.html) — official rustup docs (no winget mention, cited to support the "unconfirmed" flag above)
- [Ollama, Windows](https://docs.ollama.com/windows) — official Ollama docs (no winget mention, cited to support the "unconfirmed" flag above)
