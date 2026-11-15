#!/usr/bin/env bash
# Lints the given shell scripts (bash and POSIX sh) with shellcheck, shfmt -d and bash -n or sh -n,
# after checking both linters against .lint-versions; when a commit changes a linter's version
# (LINT_VERSIONS_MODE=sync or index), every tracked shell script is linted with it, as CI will.
# Docs: docs/repo-tooling.md
set -uo pipefail

[ "$#" -gt 0 ] || [[ ${LINT_VERSIONS_MODE:-} =~ ^(sync|index)$ ]] || exit 0

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lint-versions.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/list-lint-files.sh" || exit 1

status=0
files=("$@")
linters=()
for tool in shellcheck shfmt; do
	lv_check "$tool" || status=1
	command -v "$tool" >/dev/null 2>&1 && linters+=("$tool") && continue
	printf 'lint-bash: %s not found on PATH\n' "$tool" >&2
	status=1
done
lv_sync_file || status=1

lint_with() {
	local tool="$1" when="this commit changes" final inst
	local -a cmd=("$1")
	[ "$tool" = shfmt ] && cmd+=(-d)
	if lv_changed "$tool"; then
		[ -n "${LV_TARGET[$tool]:-}" ] && when="once .lint-versions is staged, this commit changes"
		printf 'lint-bash: %s %s to %s -- running it over every shell script, as CI will\n' \
			"$when" "$tool" "${LV_INST[$tool]}" >&2
		(
			cd "$LV_DIR" >/dev/null || exit 1
			listed=()
			llf_read_list bash listed || {
				printf 'lint-bash: could not list the shell scripts to re-lint\n' >&2
				exit 1
			}
			all=()
			for f in "${listed[@]}"; do
				[ -f "$f" ] && all+=("$f")
			done
			[ "${#all[@]}" -gt 0 ] || exit 0
			"${cmd[@]}" "${all[@]}"
		) || status=1
		return
	fi
	[ "${#files[@]}" -gt 0 ] || return 0
	"${cmd[@]}" "${files[@]}" || status=1
	final=${LV_FINAL[$tool]:-} inst=${LV_INST[$tool]:-}
	if [ -n "$final" ] && [ -n "$inst" ] && [ -z "${LV_HELD[$tool]:-}" ] && lv_version_lt "$final" "$inst"; then
		printf 'lint-bash: warning: this run used %s %s, but this commit has %s=%s, which CI will use -- it may disagree with this run.\n' \
			"$tool" "$inst" "$tool" "$final" >&2
	fi
}

for tool in "${linters[@]}"; do
	lint_with "$tool"
done

for f in "$@"; do
	shell=bash
	llf_file_shell "$f" && [ "$LLF_SHELL" = sh ] && shell='sh'
	"$shell" -n "$f" || status=1
done

exit "$status"
