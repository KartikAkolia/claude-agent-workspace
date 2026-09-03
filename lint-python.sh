#!/usr/bin/env bash
# Lints Python files with ruff (check + format --check), run via `uvx` so no
# system-wide install is needed -- same no-sudo-required shape as mdl's
# --user-install in lint-markdown.sh/CI, just via uv's tool runner instead of
# gem. No separate syntax/compile check: ruff's own parser already reports
# invalid syntax as E999, and `python3 -m py_compile` was tried and dropped --
# it ignores -B and writes __pycache__/*.pyc regardless, which isn't worth a
# gitignore entry just to duplicate a check ruff already does. Takes file
# paths as arguments, like validate-config.sh, so both the pre-commit hook
# (staged files) and lint-markdown.sh/CI (all tracked files) can share this
# one script. Callers are responsible for excluding the read-only
# ChrisTitusTech reference clones (see AGENTS.md non-negotiable #1).
set -uo pipefail

if [ "$#" -eq 0 ]; then
	exit 0
fi

status=0

if ! command -v uvx >/dev/null 2>&1; then
	printf 'lint-python: uvx not found on PATH (install uv: https://docs.astral.sh/uv/)\n' >&2
	status=1
else
	uvx ruff check "$@" || status=1
	uvx ruff format --check "$@" || status=1
fi

exit "$status"
