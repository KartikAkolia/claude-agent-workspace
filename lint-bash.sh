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

# Pinned shellcheck via uvx (shellcheck-py ships the upstream binary),
# not from PATH: distro packages lag differently (Ubuntu CI's apt 0.9.0
# flagged SC2015 where Arch's 0.11.0 didn't, 2026-10-18), so the
# pre-commit hook and CI only agree when both run this exact version.
readonly SHELLCHECK_PY_VERSION=0.11.0.1

if ! command -v uvx >/dev/null 2>&1; then
	printf 'lint-bash: uvx not found on PATH (install uv: https://docs.astral.sh/uv/)\n' >&2
	status=1
else
	uvx -q --from "shellcheck-py==$SHELLCHECK_PY_VERSION" shellcheck "$@" || status=1
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
