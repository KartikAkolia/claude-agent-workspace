#!/usr/bin/env bash
# Refreshes one ChrisTitusTech reference-clone mirror from its GitHub tarball with rsync --delete, printing
# what changes; gitignored local-only paths in the mirror are left alone, and a sync touching over half its
# tracked files needs --force-large-change.
set -uo pipefail

die() {
	printf 'refresh-reference-clone: %s\n' "$1" >&2
	exit 1
}

force_large=0
if [ "${1:-}" = --force-large-change ]; then
	force_large=1
	shift
fi
if [ "$#" -ne 3 ]; then
	printf 'usage: %s [--force-large-change] <owner/repo> <branch> <local-dir>\n' "$(basename "$0")" >&2
	exit 2
fi
upstream=$1 branch=$2 local_dir=$3

for tool in gh rsync git realpath tar; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done
case "$branch" in
'' | -* | /* | *..* | *[!A-Za-z0-9._/-]*) die "invalid branch name: $branch" ;;
esac

script_path=$(realpath -- "${BASH_SOURCE[0]}") || die "could not resolve this script's own path"
root=$(dirname -- "$script_path")
toplevel=$(git -C "$root" rev-parse --show-toplevel) || die "$root is not inside a git work tree"
toplevel=$(realpath -- "$toplevel") || die "$root is not inside a git work tree"
[ "$toplevel" = "$root" ] || die "this script's directory ($root) is not its git repo's top level ($toplevel)"

# shellcheck source=/dev/null
source "$root/list-lint-files.sh" || die "could not read the reference-clone list"
llf_reference_clone_for "$upstream" ||
	die "$upstream is not a mirrored repo -- reference-clones.tsv has: ${LLF_REFERENCE_REPOS[*]}"
mirror=$LLF_CLONE_DIR
if [ "${branch,,}" != "${LLF_CLONE_BRANCH,,}" ]; then
	printf 'refresh-reference-clone: note: %s tracks %s@%s; refreshing from %s as asked\n' \
		"$mirror" "$upstream" "$LLF_CLONE_BRANCH" "$branch" >&2
fi

# rsync --delete writes into <local-dir>: refuse, before downloading, anything but exactly the listed mirror.
mirror_path="$root/$mirror"
[ ! -L "$mirror_path" ] && [ -d "$mirror_path" ] || die "$mirror_path is missing or not a plain directory"
[ -d "$local_dir" ] || die "$local_dir does not exist or is not a directory"
resolved=$(realpath -- "$local_dir") || die "$local_dir does not exist or is not a directory"
[ "$resolved" = "$mirror_path" ] ||
	die "$local_dir resolves to $resolved, but $upstream's mirror is $mirror_path -- refusing to sync anywhere else"

tmpdir="$(mktemp -d)" || die "could not create a temporary directory"
trap 'rm -rf "$tmpdir"' EXIT
tarball="$tmpdir/upstream.tar.gz"
gh api "repos/$upstream/tarball/$branch" >"$tarball" || die "failed to download tarball for $upstream@$branch"
extract_dir="$tmpdir/extracted"
mkdir -p "$extract_dir" || die "could not create $extract_dir"
tar -xzf "$tarball" -C "$extract_dir" || die "failed to extract tarball for $upstream@$branch"
upstream_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)"
case "$upstream_root" in
'' | *$'\n'*) die "expected exactly one top-level directory in the tarball under $extract_dir" ;;
esac

ignored="$tmpdir/ignored"
git -C "$root" ls-files -z --others --ignored --exclude-standard --directory -- "$mirror/" >"$ignored" ||
	die "could not list the gitignored paths in $mirror"
sync_opts=(-rlcE --delete)
while IFS= read -r -d '' p; do
	rel=${p#"$mirror"/}
	rel=${rel%/}
	case "$rel" in
	'') continue ;;
	*$'\n'*) die "can't keep the local-only $p out of the sync (its name has a newline) -- move it out of $mirror and rerun" ;;
	*[*?[]*) rel=$(printf '%s' "$rel" | LC_ALL=C sed 's/[][\\*?]/\\&/g') ;;
	esac
	sync_opts+=("--exclude=/$rel")
done <"$ignored"

run_sync() {
	local line opts=("${sync_opts[@]}")
	[ "$1" = check ] && opts+=(--dry-run)
	LC_ALL=C rsync "${opts[@]}" --itemize-changes "$upstream_root/" "$mirror_path/" >"$tmpdir/rsync-out" || return 1
	while IFS= read -r line; do
		case "$line" in
		'*deleting '* | [\<\>ch.][fdLDS]?????????' '*) printf '%s\n' "$line" ;;
		'cannot delete non-empty directory: '*) ;;
		*) printf 'refresh-reference-clone: note: %s\n' "$line" >&2 ;;
		esac
	done <"$tmpdir/rsync-out"
}

changes="$tmpdir/changes.txt"
run_sync check >"$changes" || die "could not compare $mirror with $upstream@$branch (rsync dry run failed)"
if [ ! -s "$changes" ]; then
	printf '%s: already current with %s@%s\n' "$mirror" "$upstream" "$branch"
	exit 0
fi
printf '%s: changes found against %s@%s:\n' "$mirror" "$upstream" "$branch"
cat "$changes"

tracked=$(git -C "$root" ls-files -z -- "$mirror/" | tr -cd '\0' | wc -c)
affected=0
while IFS= read -r line; do
	case "$line" in
	'*deleting '*/) ;;
	'*deleting '* | [\>c][fL][!+]????????' '*) affected=$((affected + 1)) ;;
	esac
done <"$changes"
[ "$tracked" -gt 0 ] && [ $((affected * 2)) -gt "$tracked" ] && [ "$force_large" -eq 0 ] &&
	die "this would delete or overwrite $affected of the $tracked files git tracks in $mirror -- the wrong upstream, or a wrong line in reference-clones.tsv, looks like that. Nothing was changed; if upstream really changed that much, rerun with --force-large-change"

run_sync apply >/dev/null || die "rsync failed -- $mirror may be partly updated; check git status -- $mirror"
run_sync check >"$changes" || die "synced, but could not re-check $mirror (rsync dry run failed)"
if [ -s "$changes" ]; then
	printf 'refresh-reference-clone: synced, but rsync still reports differences:\n' >&2
	cat "$changes" >&2
	exit 1
fi
printf '%s: synced from %s@%s\n' "$mirror" "$upstream" "$branch"
