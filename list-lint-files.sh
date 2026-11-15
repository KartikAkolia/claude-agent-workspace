#!/usr/bin/env bash
# Lists the tracked files one lint category (markdown, config, bash, python) applies to, skipping
# node_modules and the reference clones in reference-clones.tsv, which only this script parses.
# Sourced, it provides the llf_* helpers the lint scripts and the pre-commit hook share.
# shellcheck disable=SC2034
LLF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

llf_load_reference_clones() {
	local file="$LLF_DIR/reference-clones.tsv" line n=0 dir repo branch err i owner allowed
	local -a words=() owners=() line_of=()
	LLF_REFERENCE_CLONES=() LLF_REFERENCE_REPOS=() LLF_REFERENCE_BRANCHES=() LLF_REFERENCE_OWNERS=()
	if [ ! -r "$file" ]; then
		printf 'list-lint-files: %s is missing or unreadable\n' "$file" >&2
		return 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}
		line=${line%%#*}
		read -r -a words <<<"$line"
		dir=${words[0]:-} repo=${words[1]:-} branch=${words[2]:-} err="" owners=()
		if [ -z "$dir" ]; then
			continue
		elif [ "$dir" = @owners ]; then
			owners=("${words[@]:1}")
			[ "${#owners[@]}" -gt 0 ] || err="@owners needs at least one owner"
		elif [ "${#words[@]}" -ne 3 ] || [[ ! $dir =~ ^[A-Za-z0-9._-]+$ || $dir == . || $dir == .. ]] ||
			[[ ! $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
			[[ ! $branch =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ || $branch == *..* ]]; then
			err="want \"<dir> <owner/repo> <branch>\", got: $line"
		elif [ "$dir" != "${repo#*/}-$branch" ]; then
			err="$dir should be named ${repo#*/}-$branch (<repo>-<branch>)"
		fi
		for owner in "${owners[@]}"; do
			[[ $owner =~ ^[A-Za-z0-9._-]+$ ]] || err=${err:-"$owner is not a GitHub owner name"}
		done
		for i in "${!LLF_REFERENCE_CLONES[@]}"; do
			[ "${LLF_REFERENCE_CLONES[i]}" != "$dir" ] && [ "${LLF_REFERENCE_REPOS[i],,}" != "${repo,,}" ] ||
				err=${err:-"$dir or $repo is already listed"}
		done
		if [ -n "$err" ]; then
			printf 'list-lint-files: %s:%s: %s\n' "$file" "$n" "$err" >&2
			return 1
		fi
		LLF_REFERENCE_OWNERS+=("${owners[@]}")
		[ "$dir" = @owners ] && continue
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
	printf -v allowed '/%s' "${LLF_REFERENCE_OWNERS[@],,}"
	for i in "${!LLF_REFERENCE_REPOS[@]}"; do
		owner=${LLF_REFERENCE_REPOS[i]%%/*}
		[[ $allowed/ == */"${owner,,}"/* ]] && continue
		printf 'list-lint-files: %s:%s: %s is not a reference-clone owner (@owners: %s)\n' "$file" "${line_of[i]}" "$owner" "${LLF_REFERENCE_OWNERS[*]}" >&2
		return 1
	done
}

llf_reference_clone_for() {
	local i
	LLF_CLONE_DIR="" LLF_CLONE_BRANCH=""
	for i in "${!LLF_REFERENCE_REPOS[@]}"; do
		[ "${LLF_REFERENCE_REPOS[i],,}" = "${1,,}" ] || continue
		LLF_CLONE_DIR=${LLF_REFERENCE_CLONES[i]} LLF_CLONE_BRANCH=${LLF_REFERENCE_BRANCHES[i]}
		return 0
	done
	return 1
}

if ! llf_load_reference_clones; then
	[ "${BASH_SOURCE[0]}" = "$0" ] && exit 1
	return 1
fi

llf_excluded() {
	local dir
	for dir in "${LLF_REFERENCE_CLONES[@]}"; do
		[[ $1 == "$dir"/* ]] && return 0
	done
	[[ /$1/ == */node_modules/* || /$1/ == */.git/* ]]
}

llf_name_category() {
	LLF_CATEGORY=""
	case "$1" in
	*.md) LLF_CATEGORY=markdown ;;
	*.json | *.yml | *.yaml) LLF_CATEGORY=config ;;
	*.py) LLF_CATEGORY=python ;;
	*) return 1 ;;
	esac
}

llf_shell_of() {
	local line="${1%$'\r'}" i=0
	local -a words
	LLF_SHELL=""
	[[ $line == '#!'* ]] || return 1
	read -r -a words <<<"${line#'#!'}"
	[ "${#words[@]}" -gt 0 ] || return 1
	[ "${words[0]##*/}" = env ] && i=1
	while [ "$i" -gt 0 ] && [ "$i" -lt "${#words[@]}" ] && [[ ${words[i]} == -* || ${words[i]} == *=* ]]; do
		i=$((i + 1))
	done
	[ "$i" -lt "${#words[@]}" ] || return 1
	case "${words[i]##*/}" in
	bash) LLF_SHELL=bash ;;
	sh | dash) LLF_SHELL='sh' ;;
	*) return 1 ;;
	esac
}

llf_file_shell() {
	local line=""
	LLF_SHELL=""
	[ -f "$1" ] || return 1
	IFS= read -r -n 512 line <"$1" 2>/dev/null
	llf_shell_of "$line"
}

# The path rules llf_filter and the pre-commit hook share: sets LLF_CATEGORY for $1 by extension, else bash
# for a shell shebang, and fails for an excluded path or one no linter takes.
llf_category_of() {
	llf_excluded "$1" && return 1
	llf_name_category "$1" && return 0
	llf_file_shell "$LLF_DIR/$1" && LLF_CATEGORY=bash
}

llf_filter() {
	local category="$1" end='\n' f found=0
	[ "$2" = nul ] && end='\0'
	while IFS= read -r -d '' f; do
		{ llf_category_of "$f" && [ "$LLF_CATEGORY" = "$category" ]; } || continue
		if [ "$end" = '\n' ] && [[ $f == *$'\n'* ]]; then
			printf 'list-lint-files: %q has a newline in its name -- list with -z\n' "$f" >&2
			return 1
		fi
		printf '%s%b' "$f" "$end"
		found=1
	done
	[ "$found" -eq 1 ] || return 3
}

llf_list() {
	local category="$1" sep="$2"
	local -a rc=()
	if [[ ! $category =~ ^(markdown|config|bash|python)$ ]]; then
		printf 'list-lint-files: unknown category %q (want: markdown, config, bash, python)\n' "$category" >&2
		return 2
	fi
	git -C "$LLF_DIR" ls-files -z -- "${LLF_REFERENCE_CLONES[@]/#/:(exclude)}" | llf_filter "$category" "$sep"
	rc=("${PIPESTATUS[@]}")
	if [ "${rc[0]}" -ne 0 ]; then
		printf 'list-lint-files: git ls-files failed (exit %s)\n' "${rc[0]}" >&2
		return 1
	fi
	[ "${rc[1]}" -ne 3 ] || printf 'list-lint-files: no %s files found -- every category has some in this repo, so something is wrong\n' "$category" >&2
	[ "${rc[1]}" -eq 0 ] || return 1
}

# Fills array $2 with category $1's files. Via a file, not < <(...), which would hide a lister failure.
llf_read_list() {
	local _llf_tmp _llf_rc
	_llf_tmp=$(mktemp) || return 1
	llf_list "$1" nul >"$_llf_tmp"
	_llf_rc=$?
	[ "$_llf_rc" -eq 0 ] && mapfile -d '' -t "$2" <"$_llf_tmp"
	rm -f "$_llf_tmp"
	return "$_llf_rc"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
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
