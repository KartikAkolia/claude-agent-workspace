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
#
# Runs exactly the ruff version in .lint-versions (set by hand, see
# lint-versions.sh), locally and in CI alike. A bare `uvx ruff` would
# keep reusing whatever version uvx first cached locally while CI fetched
# each new release, so the two could drift apart.
set -uo pipefail

# No files: nothing to do -- except in sync mode, where the pre-commit hook
# runs it for a commit that changes ruff in .lint-versions, to check the
# staged ruff line even when there's no .py file to lint.
if [ "$#" -eq 0 ] && [ "${LINT_VERSIONS_MODE:-}" != sync ]; then
	exit 0
fi

# Linted on its own (it's a tracked bash script), so not followed here.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lint-versions.sh"

status=0
if [ "$LV_MODE" = sync ]; then
	# From the pre-commit hook: use the version this commit will contain
	# (the staged copy), which is what CI reads -- not an unstaged edit.
	staged_content=$(lv_git_content "")
	case $? in
	0) ;;
	3)
		# Not in the index: removed by this commit, never staged, or missing
		# altogether -- each needs a different fix. A git error reading HEAD
		# is its own case, not "HEAD doesn't have it".
		lv_git_content HEAD >/dev/null
		case $? in
		0) lv_removed_msg lint-python ;;
		3)
			if [ -f "$LV_FILE" ]; then
				printf 'lint-python: %s is not staged -- git add it and commit again\n' "$LV_NAME" >&2
			else
				printf 'lint-python: %s is missing -- create it with a ruff=X.Y.Z line (see lint-versions.sh), stage it, and commit again\n' "$LV_FILE" >&2
			fi
			;;
		*) printf 'lint-python: could not read %s from HEAD (see the git error above)\n' "$LV_NAME" >&2 ;;
		esac
		exit 1
		;;
	*)
		printf 'lint-python: could not read the staged %s (see the git error above)\n' "$LV_NAME" >&2
		exit 1
		;;
	esac
	ruff_version=$(lv_parse ruff <<<"$staged_content")
	ruff_source="the staged $LV_NAME"
else
	ruff_version=$(lv_get ruff)
	ruff_source=$LV_FILE
	if [ ! -f "$LV_FILE" ]; then
		printf 'lint-python: %s is missing\n' "$LV_FILE" >&2
		exit 1
	fi
fi

if [ -z "$ruff_version" ]; then
	printf 'lint-python: no valid ruff=X.Y.Z line in %s\n' "$ruff_source" >&2
	status=1
elif ! command -v uvx >/dev/null 2>&1; then
	printf 'lint-python: uvx not found on PATH (install uv: https://docs.astral.sh/uv/)\n' >&2
	status=1
elif [ "$#" -gt 0 ]; then
	uvx "ruff@$ruff_version" check "$@" || status=1
	uvx "ruff@$ruff_version" format --check "$@" || status=1
else
	# Nothing to lint (a commit that only changes ruff, in a tree with no
	# .py files): still make sure that version resolves, or CI fails
	# installing it.
	if ! uvx -q "ruff@$ruff_version" --version >/dev/null; then
		printf 'lint-python: ruff %s (from %s) could not be installed -- check the version\n' "$ruff_version" "$ruff_source" >&2
		status=1
	fi
fi

exit "$status"
