#!/usr/bin/env bash
# Refreshes one of this repo's static ChrisTitusTech reference-clone mirrors
# (see AGENTS.md non-negotiable #1) from its GitHub upstream tarball. Reports
# what the sync will add, remove or change, and only touches the local dir
# if upstream content actually differs.
#
# Usage: refresh-reference-clone.sh [--force-large-change] <owner/repo>
# <branch> <local-dir>. --force-large-change lets through a sync that would
# delete or overwrite more than half the mirror's tracked files (see below).
#
# The sync is an rsync --delete, so <local-dir> must resolve to exactly the
# mirror reference-clones.tsv gives <owner/repo>, directly under the repo
# root this script lives in. Anything else -- ".", "docs", a path outside
# the repo, a symlink to the root, the other mirror's name -- is refused
# before anything is downloaded. Gitignored, untracked paths inside the
# mirror (e.g. website-master/.claude/, see .gitignore) are local-only, so
# the sync leaves them alone: neither deleted nor overwritten.
#
# The change report is a dry run of the very rsync that does the sync --
# same options, same exclusions -- so it lists exactly what will change,
# and once synced a rerun reports nothing. It compares content (checksums),
# symlinks and the executable bit, which is what git tracks; not mtimes,
# which differ between a tarball and a checkout without meaning anything.
set -uo pipefail

usage() {
	printf 'usage: %s [--force-large-change] <owner/repo> <branch> <local-dir>\n' "$(basename "$0")" >&2
}

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
	usage
	exit 2
fi

upstream="$1"
branch="$2"
local_dir="$3"

for tool in gh rsync git realpath tar; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

# It ends up in the gh api path, so nothing that could step outside it.
case "$branch" in
'' | -* | /* | *..* | *[!A-Za-z0-9._/-]*) die "invalid branch name: $branch" ;;
esac

# The repo root is wherever this script really lives, cross-checked
# against git so a stray copy elsewhere can't treat its own directory as
# the repo.
if ! script_path=$(realpath -- "${BASH_SOURCE[0]}"); then
	die "could not resolve this script's own path"
fi
root=$(dirname -- "$script_path")
if ! toplevel=$(git -C "$root" rev-parse --show-toplevel) || ! toplevel=$(realpath -- "$toplevel"); then
	die "$root is not inside a git work tree"
fi
if [ "$toplevel" != "$root" ]; then
	die "this script's directory ($root) is not its git repo's top level ($toplevel)"
fi

# The mirror for $upstream, from reference-clones.tsv via the lister's
# parser (which fails, saying why, on a missing or malformed file).
# shellcheck source=/dev/null
source "$root/list-lint-files.sh" || die "could not read the reference-clone list"
if ! llf_reference_clone_for "$upstream"; then
	die "$upstream is not a mirrored repo -- reference-clones.tsv has: ${LLF_REFERENCE_REPOS[*]}"
fi
mirror=$LLF_CLONE_DIR
if [ "${branch,,}" != "${LLF_CLONE_BRANCH,,}" ]; then
	printf 'refresh-reference-clone: note: %s tracks %s@%s; refreshing from %s as asked\n' \
		"$mirror" "$upstream" "$LLF_CLONE_BRANCH" "$branch" >&2
fi

# Compared resolved against unresolved, so the mirror itself being a
# symlink (to the root, say) is refused too.
mirror_path="$root/$mirror"
if [ -L "$mirror_path" ] || [ ! -d "$mirror_path" ]; then
	die "$mirror_path is missing or not a plain directory"
fi
if [ ! -d "$local_dir" ] || ! resolved=$(realpath -- "$local_dir"); then
	die "$local_dir does not exist or is not a directory"
fi
if [ "$resolved" != "$mirror_path" ]; then
	die "$local_dir resolves to $resolved, but $upstream's mirror is $mirror_path -- refusing to sync anywhere else"
fi

tmpdir="$(mktemp -d)" || die "could not create a temporary directory"
trap 'rm -rf "$tmpdir"' EXIT

tarball="$tmpdir/upstream.tar.gz"
if ! gh api "repos/$upstream/tarball/$branch" >"$tarball"; then
	die "failed to download tarball for $upstream@$branch"
fi

extract_dir="$tmpdir/extracted"
mkdir -p "$extract_dir" || die "could not create $extract_dir"
if ! tar -xzf "$tarball" -C "$extract_dir"; then
	die "failed to extract tarball for $upstream@$branch"
fi

upstream_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)"
case "$upstream_root" in
'' | *$'\n'*) die "expected exactly one top-level directory in the tarball under $extract_dir" ;;
esac

# Local-only paths are excluded from the sync: --delete keeps them, upstream
# can't overwrite them, and the dry run never reports them. Each becomes an
# anchored pattern, /path, matching a file or a directory. rsync only reads
# a pattern as wildcards if it has a *, ? or [ in it, and then a backslash
# escapes (see "PATTERN MATCHING RULES" in rsync(1)), so such a name gets
# each \ * ? [ ] backslash-escaped; any other name is used as it is, a
# backslash in it being literal. A newline can't be written into a rule at
# all, so a name with one stops the run rather than let --delete take it.
ignored="$tmpdir/ignored"
if ! git -C "$root" ls-files -z --others --ignored --exclude-standard --directory -- "$mirror/" >"$ignored"; then
	die "could not list the gitignored paths in $mirror"
fi
sync_opts=(-rlcE --delete)
while IFS= read -r -d '' p; do
	rel=${p#"$mirror"/}
	rel=${rel%/}
	[ -n "$rel" ] || continue
	case "$rel" in
	*$'\n'*) die "can't keep the local-only $p out of the sync (its name has a newline) -- move it out of $mirror and rerun" ;;
	*[*?[]*)
		escaped=""
		for ((i = 0; i < ${#rel}; i++)); do
			c=${rel:i:1}
			case "$c" in
			\\ | \* | \? | \[ | \]) escaped+="\\$c" ;;
			*) escaped+=$c ;;
			esac
		done
		rel=$escaped
		;;
	esac
	sync_opts+=("--exclude=/$rel")
done <"$ignored"

# Runs the sync ($1 = check: a dry run) and prints the changes it makes, one
# itemized rsync line each. rsync's other stdout lines are notes, printed to
# stderr -- except "cannot delete non-empty directory": that's a directory
# upstream dropped that still holds a local-only file, which is meant to
# stay, so it isn't a change.
run_sync() {
	local -a opts=("${sync_opts[@]}")
	[ "$1" = check ] && opts+=(--dry-run)
	if ! LC_ALL=C rsync "${opts[@]}" --itemize-changes "$upstream_root/" "$mirror_path/" >"$tmpdir/rsync-out"; then
		return 1
	fi
	local line
	while IFS= read -r line; do
		case "$line" in
		# rsync's 11-character %i code: what, file type, nine attribute flags.
		'*deleting '* | [\<\>ch.][fdLDS]?????????' '*) printf '%s\n' "$line" ;;
		'cannot delete non-empty directory: '*) ;;
		*) printf 'refresh-reference-clone: note: %s\n' "$line" >&2 ;;
		esac
	done <"$tmpdir/rsync-out"
}

changes="$tmpdir/changes.txt"
if ! run_sync check >"$changes"; then
	die "could not compare $mirror with $upstream@$branch (rsync dry run failed)"
fi

if [ ! -s "$changes" ]; then
	printf '%s: already current with %s@%s\n' "$mirror" "$upstream" "$branch"
	exit 0
fi

printf '%s: changes found against %s@%s:\n' "$mirror" "$upstream" "$branch"
cat "$changes"

# A safety net under the checks above: syncing the wrong upstream into a
# mirror, or a mirror line pointing at the wrong directory, looks like
# almost everything changing. So more than half the files git tracks there
# being deleted or overwritten stops the run, unless --force-large-change
# says upstream really did change that much. New files don't count.
tracked=$(git -C "$root" ls-files -z -- "$mirror/" | tr -cd '\0' | wc -c)
affected=0
while IFS= read -r line; do
	case "$line" in
	'*deleting '*/) ;;
	'*deleting '* | [\>c][fL][!+]????????' '*) affected=$((affected + 1)) ;;
	esac
done <"$changes"
if [ "$tracked" -gt 0 ] && [ $((affected * 2)) -gt "$tracked" ] && [ "$force_large" -eq 0 ]; then
	die "this would delete or overwrite $affected of the $tracked files git tracks in $mirror -- the wrong upstream, or a wrong line in reference-clones.tsv, looks like that. Nothing was changed; if upstream really changed that much, rerun with --force-large-change"
fi

if ! run_sync apply >/dev/null; then
	die "rsync failed -- $mirror may be partly updated; check git status -- $mirror"
fi

# The same dry run again must now find nothing; if it does, the sync can't
# converge, and every later run would report changes.
if ! run_sync check >"$changes"; then
	die "synced, but could not re-check $mirror (rsync dry run failed)"
fi
if [ -s "$changes" ]; then
	printf 'refresh-reference-clone: synced, but rsync still reports differences:\n' >&2
	cat "$changes" >&2
	exit 1
fi

printf '%s: synced from %s@%s\n' "$mirror" "$upstream" "$branch"
