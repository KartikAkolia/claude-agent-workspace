#!/usr/bin/env bash
# Reads and updates .lint-versions, CI's linter versions; index, strict and unset modes only check them. Sync mode
# (the pre-commit hook) writes a newer installed shellcheck/shfmt into its line, never an older one, and fails until
# that's staged -- unless the line is held ("# hold", staged or in the tree), staged unlike HEAD's, or has an unstaged
# edit other than that bump. Usage: get <tool> | changed <tool> | sync
LV_DIR="${LINT_VERSIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)}"
readonly LV_DIR
readonly LV_NAME=.lint-versions
readonly LV_FILE="$LV_DIR/$LV_NAME"
readonly LV_MODE="${LINT_VERSIONS_MODE:-}"
declare -A LV_INST=() LV_TARGET=() LV_CHANGED=() LV_FINAL=() LV_HELD=()

lv_removed_msg() {
	local fix="undo that with git restore --staged $LV_NAME (keeps your copy on disk)."
	[ -f "$LV_FILE" ] || fix="restore it with git restore --staged --worktree $LV_NAME."
	printf '%s: this commit removes %s, which CI needs -- %s\n' "$1" "$LV_NAME" "$fix" >&2
}

lv_line() {
	awk -v t="$1" '{ k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (k == t) { print; exit } }'
}

lv_parse() {
	lv_line "$1" | awk '{
		v = $0
		if (!sub(/^[^=#]*=/, "", v)) next
		sub(/#.*/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
		if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print v
	}'
}

lv_invalid() {
	local content
	content=$(cat)
	[ -n "$(lv_line "$1" <<<"$content")" ] && [ -z "$(lv_parse "$1" <<<"$content")" ]
}

lv_held() {
	lv_line "$1" | awk '{
		c = $0
		if (sub(/^[^#]*#/, "", c)) { gsub(/^[[:space:]]+/, "", c); if (tolower(c) ~ /^hold([^[:alnum:]_]|$)/) found = 1 }
	} END { exit !found }'
}

lv_get() {
	[ -f "$LV_FILE" ] && lv_parse "$1" <"$LV_FILE"
}

lv_git() {
	git -C "$LV_DIR" "$@"
}

# .lint-versions at revision $1 ("" for the index): 0 if there, 3 if not (or HEAD is unborn), 1 on a git error.
lv_git_content() {
	local listed content ref
	if [ -z "$1" ]; then
		listed=$(lv_git ls-files --stage -- "$LV_NAME") || return 1
	elif lv_git rev-parse --verify -q "$1^{commit}" >/dev/null; then
		listed=$(lv_git ls-tree "$1" -- "$LV_NAME") || return 1
	elif ref=$(lv_git symbolic-ref -q "$1") && {
		lv_git show-ref --verify -q "$ref"
		[ "$?" -eq 1 ]
	}; then
		return 3
	else
		printf 'lint-versions: cannot resolve %s in %s\n' "$1" "$LV_DIR" >&2
		return 1
	fi
	[ -n "$listed" ] || return 3
	content=$(lv_git show "$1:./$LV_NAME") || return 1
	printf '%s\n' "$content" | tr -d '\r'
}

lv_get_git() {
	local content
	content=$(lv_git_content "$2") || [ "$?" -eq 3 ] || return 1
	lv_parse "$1" <<<"$content"
}

lv_version_lt() {
	local IFS=. i a b
	read -r -a a <<<"$1"
	read -r -a b <<<"$2"
	for i in 0 1 2; do
		((10#${a[i]} < 10#${b[i]})) && return 0
		((10#${a[i]} > 10#${b[i]})) && return 1
	done
	return 1
}

lv_installed() {
	command -v "$1" >/dev/null 2>&1 || return 0
	case "$1" in
	shellcheck) shellcheck --version | awk '/^version:/ { print $2 }' ;;
	shfmt) shfmt --version ;;
	esac | tr -d '\r' | sed 's/^v//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

lv_changed() {
	[[ -v LV_CHANGED[$1] ]]
}

lv_warn_line() {
	if [ ! -f "$LV_FILE" ] || [ -z "$(lv_line "$1" <"$LV_FILE")" ]; then
		printf 'lint-versions: warning: %s has no %s line -- add %s=X.Y.Z (CI needs one)\n' "$LV_FILE" "$1" "$1" >&2
	elif lv_invalid "$1" <"$LV_FILE"; then
		printf 'lint-versions: warning: the %s line in %s is not %s=X.Y.Z -- fix it (CI needs one)\n' "$1" "$LV_FILE" "$1" >&2
	fi
}

lv_check() {
	local tool="$1" installed pinned
	installed=$(lv_installed "$tool")
	[ -n "$installed" ] && LV_INST[$tool]=$installed
	[ -z "$installed" ] && command -v "$tool" >/dev/null 2>&1 &&
		printf 'lint-versions: could not read the installed %s version -- not checking it against %s\n' "$tool" "$LV_NAME" >&2
	[ -z "$installed" ] && [ "$LV_MODE" = strict ] && return 1
	[[ $LV_MODE =~ ^(index|sync)$ || -z $installed$LV_MODE ]] || pinned=$(lv_get "$tool")
	if [ -z "$installed" ] && [ -z "$LV_MODE" ]; then
		lv_warn_line "$tool"
	elif [ "$LV_MODE" = index ]; then
		lv_index_check "$tool"
		return
	elif [ "$LV_MODE" = sync ]; then
		lv_sync_check "$tool" "$installed"
		return
	elif [ "$installed" = "$pinned" ]; then
		return 0
	elif [ "$LV_MODE" = strict ] && [ ! -f "$LV_FILE" ]; then
		printf 'lint-versions: %s is missing\n' "$LV_FILE" >&2
		return 1
	elif [ "$LV_MODE" = strict ]; then
		printf 'lint-versions: running %s %s but %s says %s\n' \
			"$tool" "$installed" "$LV_FILE" "${pinned:-<missing or invalid>}" >&2
		return 1
	elif [ -z "$pinned" ]; then
		lv_warn_line "$tool"
	elif lv_version_lt "$installed" "$pinned"; then
		printf 'lint-versions: warning: installed %s %s is older than CI'\''s %s (%s) -- CI may report findings this run misses\n' \
			"$tool" "$installed" "$pinned" "$LV_FILE" >&2
	elif lv_held "$tool" <"$LV_FILE"; then
		printf 'lint-versions: %s is held at %s in %s (%s is installed)\n' "$tool" "$pinned" "$LV_FILE" "$installed" >&2
	else
		printf 'lint-versions: warning: %s says %s=%s but %s is installed -- the next commit of a bash file through .githooks/pre-commit bumps it, unless you'\''ve changed that line yourself\n' \
			"$LV_FILE" "$tool" "$pinned" "$installed" >&2
	fi
	return 0
}

lv_sync_check() {
	local tool="$1" installed="$2" staged_content staged_rc head_content head staged tree="" have_tree=0 tree_v final
	local held="" due=0 edited=0 behind=0 edit
	if [ "$(lv_git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
		printf 'lint-versions: sync mode needs a git work tree, but %s is not in one\n' "$LV_DIR" >&2
		return 1
	fi
	staged_content=$(lv_git_content "")
	staged_rc=$?
	[ "$staged_rc" -eq 0 ] || [ "$staged_rc" -eq 3 ] || return 1
	head_content=$(lv_git_content HEAD) || [ "$?" -eq 3 ] || return 1
	if [ -f "$LV_FILE" ]; then
		tree=$(tr -d '\r' <"$LV_FILE") || return 1
		have_tree=1
	fi
	head=$(lv_parse "$tool" <<<"$head_content")
	if lv_invalid "$tool" <<<"$staged_content" ||
		{ [ -z "$head" ] && [ -z "$(lv_line "$tool" <<<"$staged_content")" ] &&
			lv_invalid "$tool" <<<"$tree"; }; then
		printf 'lint-versions: the %s line in %s (staged or working tree) is not %s=X.Y.Z -- fix it and commit again.\n' \
			"$tool" "$LV_FILE" "$tool" >&2
		return 1
	fi
	staged=$(lv_parse "$tool" <<<"$staged_content")
	tree_v=$(lv_parse "$tool" <<<"$tree")

	lv_held "$tool" <<<"$tree" && held=tree
	lv_held "$tool" <<<"$staged_content" && held=staged
	[ -n "$held" ] && LV_HELD[$tool]=1
	[ -n "$installed" ] && { [ -z "$head" ] || lv_version_lt "$head" "$installed"; } && due=1
	[ -z "$held" ] && [ "$staged" = "$head" ] && [ "$have_tree" -eq 1 ] && [ "$tree_v" != "$head" ] && edited=1
	[ "$due" -eq 1 ] && [ "$tree_v" = "$installed" ] && edited=0
	final=$staged
	if [ -z "$held" ] && [ "$staged" = "$head" ] && [ "$edited" -eq 0 ] && [ "$due" -eq 1 ]; then
		final=$installed
		LV_TARGET[$tool]=$installed
	fi
	[ -n "$installed" ] && { [ -z "$final" ] || lv_version_lt "$final" "$installed"; } && behind=1

	if [ "$behind" -eq 1 ] && [ "$held" = staged ]; then
		printf 'lint-versions: %s is held at %s (%s is installed) -- not bumping it.\n' "$tool" "$final" "$installed" >&2
	elif [ "$behind" -eq 1 ] && [ "$held" = tree ]; then
		printf 'lint-versions: %s holds %s=%s, but that hold isn'\''t staged -- this commit has %s=%s; git add %s to commit the hold.\n' \
			"$LV_FILE" "$tool" "${tree_v:-?}" "$tool" "${final:-<none>}" "$LV_NAME" >&2
	elif [ "$behind" -eq 1 ] && [ "$edited" -eq 1 ] && { [ -z "$tree_v" ] || lv_version_lt "$tree_v" "$installed"; }; then
		edit=${tree_v:-deleted}
		[ -z "$tree_v" ] && [ -n "$(lv_line "$tool" <<<"$tree")" ] && edit="not valid"
		printf 'lint-versions: not bumping %s to the installed %s: %s has an unstaged edit to that line (%s).\n' \
			"$tool" "$installed" "$LV_FILE" "$edit" >&2
	fi

	if [ -z "$final" ] && [ "$staged_rc" -eq 3 ] && [ -n "$head_content" ]; then
		lv_removed_msg lint-versions
		return 1
	elif [ -z "$final" ]; then
		printf 'lint-versions: this commit would have no %s line in %s (CI needs one) -- add %s=X.Y.Z, stage it, and commit again.\n' \
			"$tool" "$LV_NAME" "$tool" >&2
		return 1
	elif [ -z "$installed" ] && [ "$final" != "$head" ]; then
		printf 'lint-versions: warning: this commit sets %s=%s, but the installed %s'\''s version is unknown, so the hook can'\''t lint with it -- CI will, and may disagree with this run.\n' \
			"$tool" "$final" "$tool" >&2
		return 0
	elif [ -z "$installed" ]; then
		return 0
	fi
	if lv_version_lt "$installed" "$final"; then
		printf 'lint-versions: warning: installed %s %s is older than the %s=%s this commit has -- CI may report findings this run misses\n' \
			"$tool" "$installed" "$tool" "$final" >&2
	fi
	if [ "$final" = "$head" ]; then
		LV_FINAL[$tool]=$final
	elif [ "$installed" = "$final" ]; then
		LV_CHANGED[$tool]=1
	else
		printf 'lint-versions: warning: this commit sets %s=%s but %s is installed, so the hook can'\''t lint with it -- CI will, and may disagree with this run.\n' \
			"$tool" "$final" "$installed" >&2
	fi
	return 0
}

lv_index_check() {
	local tool="$1" staged_content head_content final head installed="${LV_INST[$1]:-}"
	staged_content=$(lv_git_content "") || [ "$?" -eq 3 ] || return 1
	head_content=$(lv_git_content HEAD) || [ "$?" -eq 3 ] || return 1
	final=$(lv_parse "$tool" <<<"$staged_content")
	head=$(lv_parse "$tool" <<<"$head_content")
	[ -n "$final" ] || return 1
	# shellcheck disable=SC2034
	lv_held "$tool" <<<"$staged_content" && LV_HELD[$tool]=1
	[ -n "$installed" ] || return 0
	if [ "$final" = "$head" ]; then
		# shellcheck disable=SC2034
		LV_FINAL[$tool]=$final
	elif [ "$installed" = "$final" ]; then
		LV_CHANGED[$tool]=1
	fi
	return 0
}

lv_apply() {
	awk -v targets="$1" '
		BEGIN {
			n = split(targets, order, " ")
			for (i = 1; i <= n; i++) { split(order[i], kv, "="); name[i] = kv[1]; want[kv[1]] = kv[2] }
		}
		{
			k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			if ((k in want) && !(k in done)) {
				line = $0
				if (match(line, /^[^=#]*=[[:space:]]*/)) {
					head = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
					sub(/^[^[:space:]#]*/, "", rest)
					print head want[k] rest
				} else {
					c = $0
					print k "=" want[k] (sub(/^[^#]*/, "", c) ? "  " c : "")
				}
				done[k] = 1
				next
			}
			print
		}
		END { for (i = 1; i <= n; i++) if (!(name[i] in done)) print name[i] "=" want[name[i]] }
	'
}

lv_without() {
	awk -v targets="$1" '
		BEGIN { n = split(targets, order, " "); for (i = 1; i <= n; i++) { split(order[i], kv, "="); drop[kv[1]] = 1 } }
		{ k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (!(k in drop)) print }
	'
}

lv_sync_file() {
	local t pairs="" staged rc base base_from="the staged copy" msg="" new orig
	[ "$LV_MODE" = sync ] || return 0
	for t in shellcheck shfmt; do
		[ -n "${LV_TARGET[$t]:-}" ] && pairs+="$t=${LV_TARGET[$t]} "
	done
	pairs=${pairs% }
	[ -n "$pairs" ] || return 0
	staged=$(lv_git_content "")
	rc=$?
	if [ "$rc" -eq 1 ]; then
		printf 'lint-versions: could not read the staged %s (see the git error above)\n' "$LV_NAME" >&2
		return 1
	fi
	base=$staged
	if [ ! -f "$LV_FILE" ] && [ "$rc" -ne 0 ]; then
		base=$(lv_git_content HEAD)
		case $? in
		0) base_from="HEAD's copy" ;;
		3) base="" base_from="" ;;
		*)
			printf 'lint-versions: could not read %s from HEAD (see the git error above)\n' "$LV_NAME" >&2
			return 1
			;;
		esac
	fi
	if [ -f "$LV_FILE" ]; then
		orig=$(cat "$LV_FILE" && printf x) || return 1
		orig=${orig%x}
		new=$(lv_apply "$pairs" <"$LV_FILE" && printf x) || return 1
		new=${new%x}
		[ -n "$orig" ] && [ "${orig: -1}" != $'\n' ] && new=${new%$'\n'}
		[ "$new" != "$orig" ] && msg="set $pairs in $LV_FILE to match the installed tools."
	else
		new=$({ [ -z "$base" ] || printf '%s\n' "$base"; } | lv_apply "$pairs" && printf x) || return 1
		new=${new%x}
		msg="created $LV_FILE with $pairs -- add a ruff=X.Y.Z line to it too (lint-python.sh needs one)."
		[ -n "$base_from" ] && msg="$LV_FILE was missing -- recreated it from $base_from, with $pairs."
	fi
	if [ -n "$msg" ] && ! printf '%s' "$new" >"$LV_FILE"; then
		printf 'lint-versions: could not write %s -- set %s in it by hand, stage it, and commit again.\n' "$LV_FILE" "$pairs" >&2
		for t in "${!LV_TARGET[@]}"; do unset 'LV_CHANGED[$t]'; done
		LV_TARGET=()
		return 1
	fi
	[ -n "$msg" ] && printf 'lint-versions: %s\n' "$msg" >&2
	if [ "$rc" -eq 0 ] && [ "$(tr -d '\r' <<<"$new" | lv_without "$pairs")" != "$(lv_without "$pairs" <<<"$staged")" ]; then
		printf 'lint-versions: note: %s also has other unstaged changes -- git add -p to stage only the version lines, unless you mean to commit those too.\n' "$LV_FILE" >&2
	fi
	printf 'lint-versions: %s in %s is not staged -- git add %s and commit again (for git commit <paths>, include it in the paths too).\n' \
		"$pairs" "$LV_FILE" "$LV_NAME" >&2
	return 1
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -uo pipefail
case "${1:-}" in
get)
	[ -n "${2:-}" ] || {
		printf 'usage: %s get <tool>\n' "${0##*/}" >&2
		exit 2
	}
	[ -f "$LV_FILE" ] || {
		printf '%s: %s is missing\n' "${0##*/}" "$LV_FILE" >&2
		exit 1
	}
	v=$(lv_get "$2")
	[ -n "$v" ] || {
		printf '%s: no valid %s=X.Y.Z line in %s\n' "${0##*/}" "$2" "$LV_FILE" >&2
		exit 1
	}
	printf '%s\n' "$v"
	;;
changed)
	if [[ ! ${2:-} =~ ^(shellcheck|shfmt|ruff|mdl)$ ]]; then
		printf 'usage: %s changed <shellcheck|shfmt|ruff|mdl>\n' "${0##*/}" >&2
		exit 2
	fi
	staged=$(lv_get_git "$2" "") || exit 2
	head=$(lv_get_git "$2" HEAD) || exit 2
	[ "$staged" != "$head" ]
	;;
sync)
	if [ "$LV_MODE" != sync ]; then
		printf 'usage: LINT_VERSIONS_MODE=sync %s sync\n' "${0##*/}" >&2
		exit 2
	fi
	status=0
	for tool in shellcheck shfmt; do
		lv_check "$tool" || status=1
	done
	lv_sync_file || status=1
	exit "$status"
	;;
*)
	printf 'usage: %s get <tool> | changed <tool> | sync\n' "${0##*/}" >&2
	exit 2
	;;
esac
