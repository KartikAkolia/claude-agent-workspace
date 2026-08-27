#!/usr/bin/env python
"""PreToolUse hook (Bash): nudge toward Serena's symbol tools instead of
shelling out to grep/rg/find for code search in this repo's own scripts.

Never blocks -- always allows the call. Only adds a reminder via
additionalContext when it fires. Backs up the "Tool Selection" rule in
AGENTS.md, which memory-only enforcement wasn't holding (see
feedback_use_all_tools.md, reconfirmed 2026-08-27).
"""
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if data.get("tool_name") != "Bash":
    sys.exit(0)

command = (data.get("tool_input") or {}).get("command", "") or ""

# `git commit`/`git commit --amend` never legitimately invoke grep/find as
# their actual action, no matter what the message text says (this hook's
# own commit messages, describing grep/find matching in prose, proved that
# the hard way -- twice). Exclude by command verb rather than trying to
# parse quoted strings/heredocs generically, which can't reliably tell
# "grep invoked" from "grep mentioned" anyway.
if re.match(r"^\s*git\s+commit\b", command):
    sys.exit(0)

# Strip heredoc bodies before matching -- covers other commands (not just
# git commit) that pass free text containing "grep"/"find" through a
# heredoc, e.g. `cat <<'EOF' ... EOF > notes.md`.
command_for_matching = re.sub(
    r"<<[-~]?['\"]?(\w+)['\"]?\n.*?\n\1\b", "", command, flags=re.DOTALL
)

# Only fire for grep/rg/find-style code search, not general Bash use.
if not re.search(r"\b(grep|rg|find\b.*-name|Select-String)\b", command_for_matching, re.IGNORECASE):
    sys.exit(0)

# Don't nudge for searches inside the read-only reference clones -- those
# aren't governed by the "use Serena on this repo's own code" rule, and
# AGENTS.md already forbids hand-editing them regardless.
reference_clones = (
    "dwm-titus-main",
    "linutil-main",
    "titus-ai-main",
    "website-master",
    "winutil-main",
)
if any(name in command for name in reference_clones):
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "additionalContext": (
            "Reminder (AGENTS.md Tool Selection): for symbol-level Python/code "
            "navigation or edits in this repo's own scripts, prefer Serena's "
            "find_symbol / find_referencing_symbols / replace_symbol_body over "
            "grep+edit string-matching, when the task fits."
        ),
    }
}))
sys.exit(0)
