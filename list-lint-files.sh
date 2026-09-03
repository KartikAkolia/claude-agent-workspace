#!/usr/bin/env bash
# Discovers which repo-tracked files one lint category applies to, skipping
# the five read-only ChrisTitusTech reference clones (see AGENTS.md
# non-negotiable #1). One category per invocation -- markdown, config, bash,
# or python -- printing one file path per line for
# `mapfile -t files < <(./list-lint-files.sh <category>)`. Shared by
# lint-markdown.sh (which still runs all four categories together for a full
# local sweep) and each per-category .github/workflows/lint-*.yml (which only
# need their own category, since they're path-filtered to trigger on that
# category's files alone -- see AGENTS.md's Repository Map / SPEC.md's
# Testing & CI section for why the split happened).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

exclude_dirs=(dwm-titus-main linutil-main titus-ai-main website-master winutil-main)

category="${1:-}"

case "$category" in
markdown)
	pathspec=('*.md' ':!.*' ':!node_modules' ':!**/node_modules')
	for dir in "${exclude_dirs[@]}"; do
		pathspec+=(":!$dir")
	done
	git ls-files "${pathspec[@]}"
	;;
config)
	pathspec=('*.json' '*.yml' '*.yaml' ':!node_modules' ':!**/node_modules')
	for dir in "${exclude_dirs[@]}"; do
		pathspec+=(":!$dir")
	done
	git ls-files "${pathspec[@]}"
	;;
bash)
	# Bash scripts aren't reliably *.sh (e.g. .githooks/pre-commit has no
	# extension), so find them by shebang instead of extension.
	pathspec=(':!node_modules' ':!**/node_modules')
	for dir in "${exclude_dirs[@]}"; do
		pathspec+=(":!$dir")
	done
	mapfile -t all_files < <(git ls-files "${pathspec[@]}")
	for f in "${all_files[@]}"; do
		[ -f "$f" ] || continue
		IFS= read -r first_line <"$f" 2>/dev/null || continue
		case "$first_line" in
		'#!'*bash) printf '%s\n' "$f" ;;
		esac
	done
	;;
python)
	pathspec=('*.py' ':!node_modules' ':!**/node_modules')
	for dir in "${exclude_dirs[@]}"; do
		pathspec+=(":!$dir")
	done
	git ls-files "${pathspec[@]}"
	;;
*)
	printf 'list-lint-files: unknown category %q (want: markdown, config, bash, python)\n' "$category" >&2
	exit 1
	;;
esac
