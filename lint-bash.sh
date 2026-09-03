#!/usr/bin/env bash
# Lints bash scripts with shellcheck, shfmt, and a bash -n syntax check.
# Takes file paths as arguments, like validate-config.sh, so both the
# pre-commit hook (staged files) and lint-markdown.sh/CI (all tracked files)
# can share this one script. Callers are responsible for excluding the
# read-only ChrisTitusTech reference clones (see AGENTS.md non-negotiable #1)
# and for only passing files that are actually bash (shebang-matched, since
# not every bash script here has a .sh extension -- e.g. .githooks/pre-commit).
set -uo pipefail

if [ "$#" -eq 0 ]; then
	exit 0
fi

status=0

if ! command -v shellcheck >/dev/null 2>&1; then
	printf 'lint-bash: shellcheck not found on PATH\n' >&2
	status=1
else
	shellcheck "$@" || status=1
fi

if ! command -v shfmt >/dev/null 2>&1; then
	printf 'lint-bash: shfmt not found on PATH\n' >&2
	status=1
else
	shfmt -d "$@" || status=1
fi

for f in "$@"; do
	bash -n "$f" || status=1
done

exit "$status"
