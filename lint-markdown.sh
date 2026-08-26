#!/usr/bin/env bash
# Lints this repo's own markdown with mdl and checks local cross-references
# for rot, skipping the read-only ChrisTitusTech reference clones (see
# AGENTS.md non-negotiable #1).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

if ! command -v mdl >/dev/null 2>&1; then
	printf 'mdl not found on PATH (gem install --user-install mdl, then add the gem bin dir to PATH)\n' >&2
	exit 1
fi

exclude_dirs=(dwm-titus-main linutil-main titus-ai-main website-master winutil-main)

pathspec=('*.md' ':!.*' ':!node_modules' ':!**/node_modules')
for dir in "${exclude_dirs[@]}"; do
	pathspec+=(":!$dir")
done

mapfile -t files < <(git ls-files "${pathspec[@]}")

status=0
mdl "${files[@]}" || status=1
./check-markdown-links.py "${files[@]}" || status=1

exit "$status"
