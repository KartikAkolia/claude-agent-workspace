#!/usr/bin/env bash
# Lints this repo's own markdown with mdl, skipping the read-only
# ChrisTitusTech reference clones (see AGENTS.md non-negotiable #1).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v mdl >/dev/null 2>&1; then
	printf 'mdl not found on PATH (gem install --user-install mdl, then add the gem bin dir to PATH)\n' >&2
	exit 1
fi

exclude_dirs=(dwm-titus-main linutil-main titus-ai-main website-master winutil-main)

find_args=(-path './.*' -prune -o -name node_modules -prune -o)
for dir in "${exclude_dirs[@]}"; do
	find_args+=(-path "./$dir" -prune -o)
done

mapfile -t files < <(find . "${find_args[@]}" -name '*.md' -print | sort)

mdl "${files[@]}"
