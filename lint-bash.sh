#!/usr/bin/env bash
# Lints shell scripts -- bash and POSIX sh -- with shellcheck, shfmt, and a
# syntax check (bash -n, or sh -n for a #!/bin/sh script). shellcheck and
# shfmt both read the dialect from the shebang. Takes file paths as
# arguments, like validate-config.sh, so both the pre-commit hook (staged
# files) and lint-markdown.sh/CI (all tracked files) can share this one
# script. Callers are responsible for excluding the read-only
# ChrisTitusTech reference clones (see AGENTS.md non-negotiable #1) and for
# only passing shell scripts (list-lint-files.sh's "bash" category, found
# by shebang, since not every script here has a .sh extension -- e.g.
# .githooks/pre-commit).
#
# Both linters' versions are checked against .lint-versions first, so the
# pre-commit hook and CI run the same versions -- see lint-versions.sh for
# how a mismatch is handled in each LINT_VERSIONS_MODE.
set -uo pipefail

# No files: nothing to do -- except in sync or index mode, where the
# pre-commit hook runs it for a commit that only changes .lint-versions, to
# check versions and do the full re-lint if one applies.
case "${LINT_VERSIONS_MODE:-}" in
sync | index) ;;
*) [ "$#" -gt 0 ] || exit 0 ;;
esac

# Linted on their own (they're tracked bash scripts), so not followed here.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lint-versions.sh"
# llf_read_list and llf_file_shell, the same rules CI lists files by.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/list-lint-files.sh" || exit 1

status=0
files=("$@")

# Version checks first, for both linters, then one write to .lint-versions
# (sync mode) -- per tool, the first tool's write would look like an
# unstaged edit to the second's check.
linters=()
for tool in shellcheck shfmt; do
	# Checked even when the tool's missing, so its .lint-versions line is
	# still validated before this commit can carry it to CI.
	lv_check "$tool" || status=1
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'lint-bash: %s not found on PATH\n' "$tool" >&2
		status=1
		continue
	fi
	linters+=("$tool")
done
lv_sync_file || status=1

# Runs one linter (lint_with <tool> <command...>) over the given files --
# or, if this commit changes the tool's version (sync mode), over every
# shell script instead, as CI will. Otherwise the commit that bumps it
# could fail CI on scripts nobody touched.
lint_with() {
	local tool="$1"
	shift
	if lv_changed "$tool"; then
		# LV_INST: lv_changed is only set when the installed version is the
		# target, and it's what actually runs.
		local when="this commit changes"
		[ -n "${LV_TARGET[$tool]:-}" ] && when="once .lint-versions is staged, this commit changes"
		printf 'lint-bash: %s %s to %s -- running it over every shell script, as CI will\n' \
			"$when" "$tool" "${LV_INST[$tool]}" >&2
		(
			cd "$LV_DIR" >/dev/null || exit 1
			# llf_read_list fails rather than return an empty list, which
			# would pass here (and shfmt -d with no files reads stdin).
			listed=()
			llf_read_list bash listed || {
				printf 'lint-bash: could not list the shell scripts to re-lint\n' >&2
				exit 1
			}
			# Tracked but deleted on disk (deletion not staged): skipped, as
			# the hook's own file lists do.
			all=()
			for f in "${listed[@]}"; do
				[ -f "$f" ] && all+=("$f")
			done
			[ "${#all[@]}" -gt 0 ] || exit 0
			"$@" "${all[@]}"
		) || status=1
	elif [ "${#files[@]}" -gt 0 ]; then
		# Guarded: shfmt -d with no files would read stdin.
		"$@" "${files[@]}" || status=1
		# Linted with a newer tool than the version this commit gives CI
		# (an edit of yours stopped the bump): CI may disagree. A held line
		# has already said why.
		local final=${LV_FINAL[$tool]:-} inst=${LV_INST[$tool]:-}
		if [ -n "$final" ] && [ -n "$inst" ] && [ -z "${LV_HELD[$tool]:-}" ] &&
			lv_version_lt "$final" "$inst"; then
			printf 'lint-bash: warning: this run used %s %s, but this commit has %s=%s, which CI will use -- it may disagree with this run.\n' \
				"$tool" "$inst" "$tool" "$final" >&2
		fi
	fi
}

for tool in "${linters[@]}"; do
	case "$tool" in
	shellcheck) lint_with shellcheck shellcheck ;;
	shfmt) lint_with shfmt shfmt -d ;;
	esac
done

for f in "$@"; do
	if llf_file_shell "$f" && [ "$LLF_SHELL" = sh ]; then
		sh -n "$f" || status=1
	else
		bash -n "$f" || status=1
	fi
done

exit "$status"
