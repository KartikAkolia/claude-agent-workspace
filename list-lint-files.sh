#!/usr/bin/env bash
# Discovers which repo-tracked files one lint category applies to, skipping
# the read-only ChrisTitusTech reference clones (see AGENTS.md
# non-negotiable #1) and anything inside a node_modules directory, at any
# depth. One category per invocation -- markdown, config, bash, or python:
#   ./list-lint-files.sh -z <category>    NUL-terminated paths
#   ./list-lint-files.sh <category>       one path per line
#   ./list-lint-files.sh --reference-clones
#                                         the clones: dir, owner/repo, branch
# The clones come from reference-clones.tsv, the one list every tool reads;
# this fails, saying why, if that's missing, malformed or empty.
# Every consumer here uses -z, since a path can hold any byte but NUL. Paths
# come from git ls-files -z, so a non-ASCII name prints as itself, never
# C-quoted. Without -z a name containing a newline can't be printed
# unambiguously, so it's an error rather than a split or dropped name.
#
# A file's category is its extension when that's one of the linted ones
# (.md; .json/.yml/.yaml; .py), else its shebang: "bash" means every shell
# script lint-bash.sh handles, bash or POSIX sh (see llf_shell_of), since
# not every script here is *.sh.
#
# Fails (nonzero, with a message) if git does, or if the category matches
# no file at all: every category always has files in this repo, so an empty
# list means something broke, and a lint run over nothing must not pass.
#
# Shared by lint-markdown.sh (the full local sweep), each
# .github/workflows/lint-*.yml, lint-bash.sh's full re-lint and
# .githooks/pre-commit -- the last three source it, for the same rules as
# functions:
#   llf_excluded <path>              0 if no lint applies to the path
#   llf_name_category <path>         sets LLF_CATEGORY from the extension
#   llf_shell_of <first-line>        sets LLF_SHELL (bash or sh) from a shebang
#   llf_file_shell <file>            the same, from the file's first line
#   llf_read_list <category> <array> fills <array> with the category's files
#   llf_reference_clone_for <owner/repo>  sets LLF_CLONE_DIR/LLF_CLONE_BRANCH

# >/dev/null: an interactive shell can wrap cd in a function that prints.
# Before the first command, so file-wide: LLF_CATEGORY, LLF_SHELL and
# LLF_CLONE_* are results for the scripts that source this.
# shellcheck disable=SC2034
LLF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
LLF_CATEGORY=""
LLF_SHELL=""
LLF_CLONE_DIR=""
LLF_CLONE_BRANCH=""
# The only GitHub owners a reference clone may come from, from
# reference-clones.tsv's "@owners" line (AGENTS.md defines the mirrors as
# ChrisTitusTech's repos). A mirror line naming anyone else is refused,
# however its dir is spelled -- a check beside the <repo>-<branch> naming
# rule against a mistaken line pointing the refresh's rsync --delete at a
# project directory; trusting a new owner takes a separate, deliberate edit.
LLF_REFERENCE_OWNERS=()
# Parallel arrays, one entry per reference clone: its dir, owner/repo and
# default branch.
LLF_REFERENCE_CLONES=()
LLF_REFERENCE_REPOS=()
LLF_REFERENCE_BRANCHES=()

# Reads reference-clones.tsv into the LLF_REFERENCE_* arrays. Fails, saying
# why, if the file is missing, a line isn't <dir> <owner/repo> <branch> or
# "@owners <owner>...", a dir or repo is listed twice, there's no clone or
# no @owners line, or a clone's owner isn't one of them: a lint run that
# skips the wrong directories, or a refresh that writes into the wrong one,
# mustn't go ahead. A dir must also be named <repo>-<branch>, as GitHub
# names a branch download (website-master): refresh-reference-clone.sh
# rsyncs --delete into it, so a mistaken line naming docs or scripts can't
# turn that on the repo's own files. This is the only parser of the file:
# scripts/sync-docs-to-trilium.py and the pre-commit hook both read it
# through `list-lint-files.sh --reference-clones`, so the rules live here.
llf_load_reference_clones() {
	local file="$LLF_DIR/reference-clones.tsv" line n=0 dir repo branch extra i owner owner_ok allowed
	local -a words=() line_of=()
	LLF_REFERENCE_CLONES=() LLF_REFERENCE_REPOS=() LLF_REFERENCE_BRANCHES=() LLF_REFERENCE_OWNERS=()
	if [ ! -r "$file" ]; then
		printf 'list-lint-files: %s is missing or unreadable\n' "$file" >&2
		return 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}
		line=${line%%#*}
		dir="" repo="" branch="" extra=""
		read -r dir repo branch extra <<<"$line"
		[ -n "$dir" ] || continue
		if [ "$dir" = @owners ]; then
			read -r -a words <<<"$line"
			if [ "${#words[@]}" -lt 2 ]; then
				printf 'list-lint-files: %s:%s: @owners needs at least one owner\n' "$file" "$n" >&2
				return 1
			fi
			for owner in "${words[@]:1}"; do
				if [[ ! $owner =~ ^[A-Za-z0-9._-]+$ ]]; then
					printf 'list-lint-files: %s:%s: %s is not a GitHub owner name\n' "$file" "$n" "$owner" >&2
					return 1
				fi
				LLF_REFERENCE_OWNERS+=("$owner")
			done
			continue
		fi
		if [ -z "$branch" ] || [ -n "$extra" ] ||
			[[ ! $dir =~ ^[A-Za-z0-9._-]+$ || $dir == . || $dir == .. ]] ||
			[[ ! $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
			[[ ! $branch =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ || $branch == *..* ]]; then
			printf 'list-lint-files: %s:%s: want "<dir> <owner/repo> <branch>", got: %s\n' "$file" "$n" "$line" >&2
			return 1
		fi
		if [ "$dir" != "${repo#*/}-$branch" ]; then
			printf 'list-lint-files: %s:%s: %s should be named %s (<repo>-<branch>)\n' "$file" "$n" "$dir" "${repo#*/}-$branch" >&2
			return 1
		fi
		for i in "${!LLF_REFERENCE_CLONES[@]}"; do
			if [ "${LLF_REFERENCE_CLONES[i]}" = "$dir" ] || [ "${LLF_REFERENCE_REPOS[i],,}" = "${repo,,}" ]; then
				printf 'list-lint-files: %s:%s: %s or %s is already listed\n' "$file" "$n" "$dir" "$repo" >&2
				return 1
			fi
		done
		LLF_REFERENCE_CLONES+=("$dir")
		LLF_REFERENCE_REPOS+=("$repo")
		LLF_REFERENCE_BRANCHES+=("$branch")
		line_of+=("$n")
	done <"$file"
	if [ "${#LLF_REFERENCE_CLONES[@]}" -eq 0 ]; then
		printf 'list-lint-files: %s lists no reference clones\n' "$file" >&2
		return 1
	fi
	if [ "${#LLF_REFERENCE_OWNERS[@]}" -eq 0 ]; then
		printf 'list-lint-files: %s has no "@owners <owner>..." line saying whose repos the clones may be\n' "$file" >&2
		return 1
	fi
	# After the loop, so @owners may come anywhere in the file.
	for i in "${!LLF_REFERENCE_REPOS[@]}"; do
		owner=${LLF_REFERENCE_REPOS[i]%%/*}
		owner_ok=0
		for allowed in "${LLF_REFERENCE_OWNERS[@]}"; do
			[ "${allowed,,}" = "${owner,,}" ] && owner_ok=1
		done
		if [ "$owner_ok" -eq 0 ]; then
			printf 'list-lint-files: %s:%s: %s is not a reference-clone owner (@owners: %s)\n' "$file" "${line_of[i]}" "$owner" "${LLF_REFERENCE_OWNERS[*]}" >&2
			return 1
		fi
	done
}

# Sets LLF_CLONE_DIR and LLF_CLONE_BRANCH for upstream $1 (owner/repo,
# matched case-insensitively as on GitHub); fails if it isn't a clone's.
llf_reference_clone_for() {
	local i
	LLF_CLONE_DIR="" LLF_CLONE_BRANCH=""
	for i in "${!LLF_REFERENCE_REPOS[@]}"; do
		if [ "${LLF_REFERENCE_REPOS[i],,}" = "${1,,}" ]; then
			LLF_CLONE_DIR=${LLF_REFERENCE_CLONES[i]}
			LLF_CLONE_BRANCH=${LLF_REFERENCE_BRANCHES[i]}
			return 0
		fi
	done
	return 1
}

# Sourced, a failure fails the source (each caller checks); run, it exits.
if ! llf_load_reference_clones; then
	[ "${BASH_SOURCE[0]}" = "$0" ] && exit 1
	return 1
fi

llf_excluded() {
	local dir
	for dir in "${LLF_REFERENCE_CLONES[@]}"; do
		case "$1" in
		"$dir"/*) return 0 ;;
		esac
	done
	case "/$1/" in
	*/node_modules/* | */.git/*) return 0 ;;
	esac
	return 1
}

llf_name_category() {
	case "$1" in
	*.md) LLF_CATEGORY=markdown ;;
	*.json | *.yml | *.yaml) LLF_CATEGORY=config ;;
	*.py) LLF_CATEGORY=python ;;
	*)
		LLF_CATEGORY=""
		return 1
		;;
	esac
}

# The interpreter is the shebang's first word, or for env the first word
# after its options and NAME=value settings (`#!/usr/bin/env -S bash -e`).
# A trailing CR, from a CRLF checkout, is ignored.
llf_shell_of() {
	local line="${1%$'\r'}" i=0 interp
	local -a words
	LLF_SHELL=""
	case "$line" in
	'#!'*) ;;
	*) return 1 ;;
	esac
	read -r -a words <<<"${line#'#!'}"
	[ "${#words[@]}" -gt 0 ] || return 1
	interp=${words[0]##*/}
	if [ "$interp" = env ]; then
		i=1
		while [ "$i" -lt "${#words[@]}" ]; do
			case "${words[i]}" in
			-* | *=*) i=$((i + 1)) ;;
			*) break ;;
			esac
		done
		[ "$i" -lt "${#words[@]}" ] || return 1
		interp=${words[i]##*/}
	fi
	case "$interp" in
	bash) LLF_SHELL=bash ;;
	sh | dash) LLF_SHELL='sh' ;;
	*) return 1 ;;
	esac
}

llf_file_shell() {
	local line=""
	LLF_SHELL=""
	[ -f "$1" ] || return 1
	# -n: a binary file with no newline would otherwise be read whole.
	IFS= read -r -n 512 line <"$1" 2>/dev/null
	llf_shell_of "$line"
}

# Reads NUL-terminated paths on stdin and prints those in category $1,
# each terminated by a NUL ($2 = nul) or a newline. Returns 3 if there were
# none.
llf_filter() {
	local category="$1" sep="$2" f found=0
	while IFS= read -r -d '' f; do
		llf_excluded "$f" && continue
		if llf_name_category "$f"; then
			[ "$LLF_CATEGORY" = "$category" ] || continue
		elif [ "$category" != bash ] || ! llf_file_shell "$LLF_DIR/$f"; then
			continue
		fi
		if [ "$sep" = nul ]; then
			printf '%s\0' "$f"
		elif [[ $f == *$'\n'* ]]; then
			printf 'list-lint-files: %q has a newline in its name -- list with -z\n' "$f" >&2
			return 1
		else
			printf '%s\n' "$f"
		fi
		found=1
	done
	[ "$found" -eq 1 ] || return 3
	return 0
}

# Prints category $1's files, each terminated by a NUL ($2 = nul) or a
# newline (anything else).
llf_list() {
	local category="$1" sep="$2" dir
	local -a pathspec=() rc=()
	case "$category" in
	markdown | config | bash | python) ;;
	*)
		printf 'list-lint-files: unknown category %q (want: markdown, config, bash, python)\n' "$category" >&2
		return 2
		;;
	esac
	# The reference clones are left out here too, not just by llf_excluded,
	# so git never lists their thousands of files.
	for dir in "${LLF_REFERENCE_CLONES[@]}"; do
		pathspec+=(":(exclude)$dir")
	done
	git -C "$LLF_DIR" ls-files -z -- "${pathspec[@]}" | llf_filter "$category" "$sep"
	rc=("${PIPESTATUS[@]}")
	if [ "${rc[0]}" -ne 0 ]; then
		printf 'list-lint-files: git ls-files failed (exit %s)\n' "${rc[0]}" >&2
		return 1
	fi
	case "${rc[1]}" in
	0) return 0 ;;
	3)
		printf 'list-lint-files: no %s files found -- every category has some in this repo, so something is wrong\n' "$category" >&2
		return 1
		;;
	*) return 1 ;;
	esac
}

# Fills array $2 with category $1's files; nonzero (the lister has said
# why) on failure. Via a file, not < <(...), which would hide one.
llf_read_list() {
	local _llf_tmp _llf_rc
	_llf_tmp=$(mktemp) || return 1
	llf_list "$1" nul >"$_llf_tmp"
	_llf_rc=$?
	[ "$_llf_rc" -eq 0 ] && mapfile -d '' -t "$2" <"$_llf_tmp"
	rm -f "$_llf_tmp"
	return "$_llf_rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -uo pipefail
	if [ "${1:-}" = --reference-clones ] && [ "$#" -eq 1 ]; then
		for i in "${!LLF_REFERENCE_CLONES[@]}"; do
			printf '%s\t%s\t%s\n' "${LLF_REFERENCE_CLONES[i]}" "${LLF_REFERENCE_REPOS[i]}" "${LLF_REFERENCE_BRANCHES[i]}"
		done
		exit 0
	fi
	sep=newline
	if [ "${1:-}" = -z ]; then
		sep=nul
		shift
	fi
	if [ "$#" -ne 1 ]; then
		printf 'usage: %s [-z] <markdown|config|bash|python> | --reference-clones\n' "${0##*/}" >&2
		exit 2
	fi
	llf_list "$1" "$sep"
fi
