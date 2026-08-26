#!/usr/bin/env bash
# Refreshes one of this repo's static ChrisTitusTech reference-clone mirrors
# (see AGENTS.md non-negotiable #1) from its GitHub upstream tarball. Reports
# an added/removed/changed file summary and only touches the local dir if
# upstream content actually differs.
set -uo pipefail

usage() {
	printf 'usage: %s <owner/repo> <branch> <local-dir>\n' "$(basename "$0")" >&2
}

if [ "$#" -ne 3 ]; then
	usage
	exit 2
fi

upstream="$1"
branch="$2"
local_dir="$3"

if ! command -v gh >/dev/null 2>&1; then
	printf 'refresh-reference-clone: gh CLI not found on PATH\n' >&2
	exit 1
fi

if [ ! -d "$local_dir" ]; then
	printf 'refresh-reference-clone: %s does not exist\n' "$local_dir" >&2
	exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

tarball="$tmpdir/upstream.tar.gz"
if ! gh api "repos/$upstream/tarball/$branch" >"$tarball"; then
	printf 'refresh-reference-clone: failed to download tarball for %s@%s\n' "$upstream" "$branch" >&2
	exit 1
fi

extract_dir="$tmpdir/extracted"
mkdir -p "$extract_dir"
if ! tar -xzf "$tarball" -C "$extract_dir"; then
	printf 'refresh-reference-clone: failed to extract tarball for %s@%s\n' "$upstream" "$branch" >&2
	exit 1
fi

upstream_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)"
if [ -z "$upstream_root" ]; then
	printf 'refresh-reference-clone: could not find extracted root under %s\n' "$extract_dir" >&2
	exit 1
fi

diff_output="$tmpdir/diff.txt"
diff -rq "$upstream_root" "$local_dir" >"$diff_output" 2>&1

if [ ! -s "$diff_output" ]; then
	printf '%s: already current with %s@%s\n' "$local_dir" "$upstream" "$branch"
	exit 0
fi

printf '%s: changes found against %s@%s:\n' "$local_dir" "$upstream" "$branch"
cat "$diff_output"

rsync -a --delete "$upstream_root/" "$local_dir/"

printf '%s: synced from %s@%s\n' "$local_dir" "$upstream" "$branch"
