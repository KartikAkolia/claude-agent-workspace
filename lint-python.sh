#!/usr/bin/env bash
# Lints the given Python files with ruff check and ruff format --check, run through uvx at exactly the
# ruff version in .lint-versions -- the staged copy's under the pre-commit hook (LINT_VERSIONS_MODE=sync
# or index), where it runs even with no files so a changed ruff line is still checked.
set -uo pipefail

[ "$#" -gt 0 ] || [[ ${LINT_VERSIONS_MODE:-} =~ ^(sync|index)$ ]] || exit 0

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lint-versions.sh"

staged_ruff() {
	local content
	content=$(lv_git_content "") && {
		lv_parse ruff <<<"$content"
		return 0
	}
	[ "$?" -eq 3 ] || {
		printf 'lint-python: could not read the staged %s (see the git error above)\n' "$LV_NAME" >&2
		return 1
	}
	lv_git_content HEAD >/dev/null
	case $? in
	0) lv_removed_msg lint-python ;;
	3)
		if [ -f "$LV_FILE" ]; then
			printf 'lint-python: %s is not staged -- git add it and commit again\n' "$LV_NAME" >&2
		else
			printf 'lint-python: %s is missing -- create it with a ruff=X.Y.Z line (format: docs/repo-tooling.md), stage it, and commit again\n' "$LV_FILE" >&2
		fi
		;;
	*) printf 'lint-python: could not read %s from HEAD (see the git error above)\n' "$LV_NAME" >&2 ;;
	esac
	return 1
}

status=0
if [ "$LV_MODE" = sync ] || [ "$LV_MODE" = index ]; then
	ruff_version=$(staged_ruff) || exit 1
	ruff_source="the staged $LV_NAME"
elif [ -f "$LV_FILE" ]; then
	ruff_version=$(lv_get ruff)
	ruff_source=$LV_FILE
else
	printf 'lint-python: %s is missing\n' "$LV_FILE" >&2
	exit 1
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
elif ! uvx -q "ruff@$ruff_version" --version >/dev/null; then
	printf 'lint-python: ruff %s (from %s) could not be installed -- check the version\n' "$ruff_version" "$ruff_source" >&2
	status=1
fi

exit "$status"
