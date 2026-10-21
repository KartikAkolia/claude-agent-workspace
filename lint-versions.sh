#!/usr/bin/env bash
# lint-versions.sh — reads and updates .lint-versions, the linter versions
# CI installs, so the pre-commit hook and CI run the same ones. Distro
# packages lag differently (Ubuntu CI's apt shellcheck 0.9.0 flagged SC2015
# where Arch's 0.11.0 didn't, 2026-10-18; its apt shfmt was 3.8.0 against
# Arch's 3.14.1), so CI only agrees with the hook when it runs these exact
# versions.
#
# .lint-versions holds one tool=X.Y.Z line per tool (the first line for a
# tool is the one that counts). # starts a comment, whole-line or trailing.
#   For shellcheck and shfmt: follow the newest installed on Kartik's machines.
#     lint-bash.sh calls lv_check for each, then lv_sync_file once, which
#     handle a mismatch per LINT_VERSIONS_MODE:
#       sync   (.githooks/pre-commit): see "Sync mode" below.
#       strict (lint-bash.yml): installed must equal the file exactly, since
#              the workflow installed what the file says.
#       unset  (lint-markdown.sh's sweep, one-off runs): warn, write nothing.
#   ruff: set by hand. uvx runs exactly this version locally and in CI, so
#     there's no installed copy to follow.
#
# Sync mode answers one question per tool: did you set this line on
# purpose? Then the hook leaves it alone. You did if:
#   - its trailing comment starts with the word "hold", in the staged copy
#     or the working tree (`shellcheck=0.10.0  # hold: 0.11 regressed`) --
#     e.g. to keep a rollback in place across later commits;
#   - the staged version differs from HEAD's (you staged an upgrade or a
#     rollback); or
#   - the working-tree version differs from HEAD's but isn't staged (an
#     edit in progress; like any unstaged edit, it's not in this commit) --
#     unless it's exactly the installed version while a bump is due: that's
#     the bump itself (the hook's earlier write, or yours), so the commit
#     fails until it's staged.
# Otherwise the line is untouched, and a newer installed version is written
# into it (all tools in one write, trailing comment kept) and the commit
# fails until that's staged. An installed version older than the line only
# warns -- it's never downgraded. Whenever this commit changes a version
# from HEAD's, every bash script is re-linted with it, as CI will -- if
# that's the installed version; if not, the hook says CI's verdict may
# differ from its own.
#
# Sourced by lint-bash.sh and lint-python.sh. The workflows run it directly:
#   ./lint-versions.sh get <tool>      print <tool>'s version, or fail
#   ./lint-versions.sh changed <tool>  exit 0 if the staged version differs
#                                      from HEAD's, 1 if not, 2 on a git or
#                                      usage error. .githooks/pre-commit uses
#                                      it to lint every file of a kind when a
#                                      commit changes that kind's linter, and
#                                      fails the commit on 2 -- so an error
#                                      must never come back as 1.
#
# Known limitation: "this commit changes the version" means "differs from
# HEAD", and a pre-commit hook can't tell it's running for `git commit
# --amend`, where HEAD is the commit being amended. So amending a commit
# that already bumped a version doesn't trigger the full re-lint again;
# CI's own full lint with that version is the backstop there.

# >/dev/null: an interactive shell can wrap cd in a function that prints.
LV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly LV_DIR
readonly LV_NAME=.lint-versions
readonly LV_FILE="$LV_DIR/$LV_NAME"
readonly LV_MODE="${LINT_VERSIONS_MODE:-}"

# Per tool: the installed version lv_check read; (sync) the version the
# working tree needs written, for lv_sync_file; and (sync) whether this
# commit changes the version from HEAD's with the installed tool being that
# version, so lint-bash.sh re-lints every bash script with it.
# LV_FINAL/LV_HELD: (sync) the version this commit gives CI, and whether
# that line is held -- so lint-bash.sh can warn when it lints with a newer
# installed tool than that, but only for a tool it actually runs.
declare -A LV_INST=() LV_TARGET=() LV_CHANGED=() LV_FINAL=() LV_HELD=()

# The message for a commit that removes .lint-versions from the index while
# HEAD has it. --worktree only when the file's gone from disk too:
# otherwise it would throw away whatever unstaged edits it holds. $1 is the
# message prefix (the calling script's name).
lv_removed_msg() {
	if [ -f "$LV_FILE" ]; then
		printf '%s: this commit removes %s, which CI needs -- undo that with git restore --staged %s (keeps your copy on disk).\n' \
			"$1" "$LV_NAME" "$LV_NAME" >&2
	else
		printf '%s: this commit removes %s, which CI needs -- restore it with git restore --staged --worktree %s.\n' \
			"$1" "$LV_NAME" "$LV_NAME" >&2
	fi
}

# Prints the first line for tool $1 in .lint-versions content on stdin, if
# any. A line's tool is everything before its first = or # (so
# `shellcheck # hold`, with no version, is still shellcheck's -- invalid,
# not missing). Every reader goes through it, so the version and the hold
# marker always come from the same line.
lv_line() {
	awk -v t="$1" '{ k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (k == t) { print; exit } }'
}

# Prints $1's version from .lint-versions content on stdin: the value on
# its line, if that's a valid X.Y.Z (spaces and a trailing # comment
# allowed). Nothing if there's no line or it isn't valid.
lv_parse() {
	lv_line "$1" | awk '{
		v = $0
		if (!sub(/^[^=#]*=/, "", v)) next
		# Ends only: a space inside (`0.1 0.0`) makes the value invalid,
		# rather than quietly reading as 0.10.0.
		sub(/#.*/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
		if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print v
	}'
}

# 0 if content on stdin has a line for $1 whose value isn't a valid X.Y.Z.
lv_invalid() {
	local content line
	content=$(cat)
	line=$(lv_line "$1" <<<"$content")
	[ -n "$line" ] && [ -z "$(lv_parse "$1" <<<"$content")" ]
}

# 0 if $1's line in .lint-versions content on stdin is held: its trailing
# comment starts with the word "hold" (`# hold`, `# hold: why`).
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

# Prints .lint-versions as of git revision $1 ("HEAD", or "" for the
# index), CRs stripped. Returns 0 if it's there, 3 if it isn't (or HEAD is
# an unborn branch), and 1 on a real git error -- which must never read as
# "not there".
lv_git_content() {
	local listed content
	if [ -z "$1" ]; then
		listed=$(lv_git ls-files --stage -- "$LV_NAME") || return 1
	else
		if ! lv_git rev-parse --verify -q "$1^{commit}" >/dev/null; then
			# An unborn branch (no commits yet, including a new --orphan
			# branch in a repo that has others) names a ref that doesn't
			# exist: show-ref exits 1 for that, but 128 for a ref that exists
			# and is broken.
			local ref rc
			if ref=$(lv_git symbolic-ref -q "$1"); then
				lv_git show-ref --verify -q "$ref"
				rc=$?
				[ "$rc" -eq 1 ] && return 3
			fi
			printf 'lint-versions: cannot resolve %s in %s\n' "$1" "$LV_DIR" >&2
			return 1
		fi
		listed=$(lv_git ls-tree "$1" -- "$LV_NAME") || return 1
	fi
	[ -n "$listed" ] || return 3
	content=$(lv_git show "$1:./$LV_NAME") || return 1
	printf '%s\n' "$content" | tr -d '\r'
}

# Prints $1's version as of git revision $2 (see lv_git_content); nothing
# if the file isn't there. Returns 1 only on a git error.
lv_get_git() {
	local content rc
	content=$(lv_git_content "$2")
	rc=$?
	[ "$rc" -eq 3 ] && return 0
	[ "$rc" -eq 0 ] || return 1
	lv_parse "$1" <<<"$content"
}

# Pure-bash X.Y.Z comparison (not sort -V, which older macOS sort lacks).
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

# Leading X.Y.Z of the installed tool, so a git/distro build like
# 0.11.0-12-gabcdef reads as 0.11.0; tr strips Git Bash's CRLF on Windows.
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

# Unset mode: warns if .lint-versions has no line for $1, or one that
# isn't tool=X.Y.Z -- the two need different fixes.
lv_warn_line() {
	if [ ! -f "$LV_FILE" ] || [ -z "$(lv_line "$1" <"$LV_FILE")" ]; then
		printf 'lint-versions: warning: %s has no %s line -- add %s=X.Y.Z (CI needs one)\n' "$LV_FILE" "$1" "$1" >&2
	elif lv_invalid "$1" <"$LV_FILE"; then
		printf 'lint-versions: warning: the %s line in %s is not %s=X.Y.Z -- fix it (CI needs one)\n' "$1" "$LV_FILE" "$1" >&2
	fi
}

# Checks one tool's installed version against .lint-versions. Never writes
# the file: in sync mode it records what the working tree needs in
# LV_TARGET, and lv_sync_file makes one write for every tool afterwards.
lv_check() {
	local tool="$1" installed pinned head staged tree="" have_tree=0 tree_v staged_content head_content rc final
	installed=$(lv_installed "$tool")
	if [ -z "$installed" ]; then
		# e.g. a `go install` shfmt that reports "(devel)". Strict (CI) needs
		# the exact version; elsewhere a warning, so one odd build doesn't
		# block every commit on that host -- other hosts still keep
		# .lint-versions current. Sync still checks the line itself below.
		# A tool that isn't installed at all is lint-bash.sh's to report.
		command -v "$tool" >/dev/null 2>&1 &&
			printf 'lint-versions: could not read the installed %s version -- not checking it against %s\n' "$tool" "$LV_NAME" >&2
		[ "$LV_MODE" = strict ] && return 1
		if [ -z "$LV_MODE" ]; then
			lv_warn_line "$tool"
			return 0
		fi
	else
		# Read by lint-bash.sh, which sources this file.
		# shellcheck disable=SC2034
		LV_INST[$tool]=$installed
	fi

	if [ "$LV_MODE" != sync ]; then
		pinned=$(lv_get "$tool")
		if [ "$LV_MODE" = strict ]; then
			[ "$installed" = "$pinned" ] && return 0
			if [ ! -f "$LV_FILE" ]; then
				printf 'lint-versions: %s is missing\n' "$LV_FILE" >&2
			else
				printf 'lint-versions: running %s %s but %s says %s\n' \
					"$tool" "$installed" "$LV_FILE" "${pinned:-<missing or invalid>}" >&2
			fi
			return 1
		fi
		[ "$installed" = "$pinned" ] && return 0
		if [ -z "$pinned" ]; then
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
	fi

	# Sync mode.
	if [ "$(lv_git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
		printf 'lint-versions: sync mode needs a git work tree, but %s is not in one\n' "$LV_DIR" >&2
		return 1
	fi
	local staged_rc
	staged_content=$(lv_git_content "")
	staged_rc=$?
	case "$staged_rc" in 0) ;; 3) staged_content="" ;; *) return 1 ;; esac
	head_content=$(lv_git_content HEAD)
	rc=$?
	case "$rc" in 0) ;; 3) head_content="" ;; *) return 1 ;; esac
	if [ -f "$LV_FILE" ]; then
		tree=$(tr -d '\r' <"$LV_FILE") || return 1
		have_tree=1
	fi

	head=$(lv_parse "$tool" <<<"$head_content")
	# A staged line for the tool that doesn't parse would be committed as-is
	# and break CI's `get`. An invalid working-tree line is just an unstaged
	# edit, left alone like any other -- unless HEAD has no line either, the
	# one case where it would read as untouched and get rewritten.
	if lv_invalid "$tool" <<<"$staged_content" ||
		{ [ -z "$head" ] && [ -z "$(lv_line "$tool" <<<"$staged_content")" ] &&
			lv_invalid "$tool" <<<"$tree"; }; then
		printf 'lint-versions: the %s line in %s (staged or working tree) is not %s=X.Y.Z -- fix it and commit again.\n' \
			"$tool" "$LV_FILE" "$tool" >&2
		return 1
	fi
	staged=$(lv_parse "$tool" <<<"$staged_content")
	tree_v=$(lv_parse "$tool" <<<"$tree")

	# Did you set it on purpose? (See "Sync mode" in the header.) final is
	# what this commit will contain for the tool.
	if lv_held "$tool" <<<"$staged_content" || lv_held "$tool" <<<"$tree"; then
		final=$staged
		# shellcheck disable=SC2034
		LV_HELD[$tool]=1
		# Only worth saying when the hold is what's stopping a due bump.
		if [ -n "$installed" ] && { [ -z "$final" ] || lv_version_lt "$final" "$installed"; }; then
			if lv_held "$tool" <<<"$staged_content"; then
				printf 'lint-versions: %s is held at %s (%s is installed) -- not bumping it.\n' "$tool" "$final" "$installed" >&2
			else
				printf 'lint-versions: %s holds %s=%s, but that hold isn'\''t staged -- this commit has %s=%s; git add %s to commit the hold.\n' \
					"$LV_FILE" "$tool" "${tree_v:-?}" "$tool" "${final:-<none>}" "$LV_NAME" >&2
			fi
		fi
	elif [ "$staged" != "$head" ]; then
		final=$staged
	elif [ -n "$installed" ] && [ "$tree_v" = "$installed" ] &&
		{ [ -z "$head" ] || lv_version_lt "$head" "$installed"; }; then
		# The working tree already has the bump that's due -- the hook's own
		# earlier write (or yours, to the same version): not an edit to leave
		# alone, but a bump still to be staged, so keep failing until it is.
		final=$installed
		LV_TARGET[$tool]=$installed
	elif [ "$have_tree" -eq 1 ] && [ "$tree_v" != "$head" ]; then
		# An unstaged edit to the line -- including deleting it -- is yours.
		final=$staged
		# Only worth saying when a bump was actually due, and the edit isn't
		# already that new.
		if [ -n "$installed" ] && { [ -z "$head" ] || lv_version_lt "$head" "$installed"; } &&
			{ [ -z "$tree_v" ] || lv_version_lt "$tree_v" "$installed"; }; then
			local edit=$tree_v
			if [ -z "$edit" ]; then
				if [ -n "$(lv_line "$tool" <<<"$tree")" ]; then edit="not valid"; else edit="deleted"; fi
			fi
			printf 'lint-versions: not bumping %s to the installed %s: %s has an unstaged edit to that line (%s).\n' \
				"$tool" "$installed" "$LV_FILE" "$edit" >&2
		fi
	elif [ -n "$installed" ] && { [ -z "$head" ] || lv_version_lt "$head" "$installed"; }; then
		# Untouched, and the installed version is newer (or there's no line
		# yet): bump it.
		final=$installed
		LV_TARGET[$tool]=$installed
	else
		final=$head
	fi

	# CI's `get` fails without a valid line, so a commit can't leave it out.
	if [ -z "$final" ]; then
		if [ "$staged_rc" -eq 3 ] && [ -n "$head_content" ]; then
			lv_removed_msg lint-versions
		else
			printf 'lint-versions: this commit would have no %s line in %s (CI needs one) -- add %s=X.Y.Z, stage it, and commit again.\n' \
				"$tool" "$LV_NAME" "$tool" >&2
		fi
		return 1
	fi

	if [ -z "$installed" ]; then
		if [ "$final" != "$head" ]; then
			printf 'lint-versions: warning: this commit sets %s=%s, but the installed %s'\''s version is unknown, so the hook can'\''t lint with it -- CI will, and may disagree with this run.\n' \
				"$tool" "$final" "$tool" >&2
		fi
		return 0
	fi
	if lv_version_lt "$installed" "$final"; then
		printf 'lint-versions: warning: installed %s %s is older than the %s=%s this commit has -- CI may report findings this run misses\n' \
			"$tool" "$installed" "$tool" "$final" >&2
	fi
	# For lint-bash.sh's "linted with a newer tool than CI" warning -- only
	# when this commit keeps the version as it was; a change was warned
	# about just above.
	# shellcheck disable=SC2034
	[ "$final" = "$head" ] && LV_FINAL[$tool]=$final
	if [ "$final" != "$head" ]; then
		if [ "$installed" = "$final" ]; then
			LV_CHANGED[$tool]=1
		else
			printf 'lint-versions: warning: this commit sets %s=%s but %s is installed, so the hook can'\''t lint with it -- CI will, and may disagree with this run.\n' \
				"$tool" "$final" "$installed" >&2
		fi
	fi
	return 0
}

# Applies "tool=X.Y.Z ..." ($1) to .lint-versions content on stdin: sets
# each tool's first line to the new version, keeping any trailing comment;
# appends any that are missing (in $1's order); passes every other line
# through untouched.
lv_apply() {
	awk -v targets="$1" '
		BEGIN {
			n = split(targets, order, " ")
			for (i = 1; i <= n; i++) { split(order[i], kv, "="); name[i] = kv[1]; want[kv[1]] = kv[2] }
		}
		{
			k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			if ((k in want) && !(k in done)) {
				# Swap just the value: everything up to and including the
				# first =, plus whatever follows the value (spacing, comment),
				# stays as written.
				line = $0
				if (match(line, /^[^=#]*=[[:space:]]*/)) {
					head = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
					sub(/^[^[:space:]#]*/, "", rest)
					print head want[k] rest
				} else {
					# No = at all (unreachable from lv_check, which rejects such
					# a line first): still keep any comment.
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

# Drops the lines of every tool in "tool=X.Y.Z ..." ($1) from .lint-versions
# content on stdin.
lv_without() {
	awk -v targets="$1" '
		BEGIN { n = split(targets, order, " "); for (i = 1; i <= n; i++) { split(order[i], kv, "="); drop[kv[1]] = 1 } }
		{ k = $0; sub(/[=#].*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (!(k in drop)) print }
	'
}

# Sync mode, once lv_check has run for every tool: writes the bumps lv_check
# decided on (only ever for lines you haven't touched) into .lint-versions
# in a single write, then fails until they're staged. A missing file is
# rebuilt from the staged copy, or HEAD's, so the ruff line and comments
# survive. Never stages anything itself, and says so when the file holds
# other unstaged changes, so "git add" doesn't commit them by surprise.
lv_sync_file() {
	local t pairs="" staged rc base base_from tree msg=""
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
	[ "$rc" -eq 3 ] && staged=""

	local new
	if [ -f "$LV_FILE" ]; then
		# awk straight over the file, not via $(...) and back: every line it
		# doesn't change passes through byte for byte (CRLF, blank and
		# whitespace-only lines included). The x keeps $(...) from eating
		# trailing newlines; a missing final newline stays missing.
		local orig
		orig=$(cat "$LV_FILE" && printf x) || return 1
		orig=${orig%x}
		new=$(lv_apply "$pairs" <"$LV_FILE" && printf x) || return 1
		new=${new%x}
		if [ -n "$orig" ] && [ "${orig: -1}" != $'\n' ]; then new=${new%$'\n'}; fi
		[ "$new" != "$orig" ] && msg="set $pairs in $LV_FILE to match the installed tools."
	else
		if [ "$rc" -eq 0 ]; then
			base=$staged
			base_from="the staged copy"
		else
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
		# if, not &&: under pipefail a false [ -n ] would fail the pipeline.
		new=$({ if [ -n "$base" ]; then printf '%s\n' "$base"; fi; } | lv_apply "$pairs" && printf x) || return 1
		new=${new%x}
		if [ -n "$base_from" ]; then
			msg="$LV_FILE was missing -- recreated it from $base_from, with $pairs."
		else
			msg="created $LV_FILE with $pairs -- add a ruff=X.Y.Z line to it too (lint-python.sh needs one)."
		fi
	fi
	tree=$(tr -d '\r' <<<"$new")

	# Only write when something changes (a retry after the bump's already on
	# disk doesn't touch the file). In place, not via mv: keeps the file's
	# mode and any symlink. On a failed write there's no bump on disk to
	# stage, so drop the targets (lint-bash.sh's messages read them).
	if [ -n "$msg" ] && ! printf '%s' "$new" >"$LV_FILE"; then
		printf 'lint-versions: could not write %s -- set %s in it by hand, stage it, and commit again.\n' "$LV_FILE" "$pairs" >&2
		for t in "${!LV_TARGET[@]}"; do unset 'LV_CHANGED[$t]'; done
		LV_TARGET=()
		return 1
	fi
	# Reported only once the write has actually happened.
	[ -n "$msg" ] && printf 'lint-versions: %s\n' "$msg" >&2

	# Other unstaged changes, the bumped lines aside? Compared with those
	# lines dropped from both sides. (Untracked: nothing's staged to differ
	# from.)
	if [ "$rc" -eq 0 ] && [ "$(lv_without "$pairs" <<<"$tree")" != "$(lv_without "$pairs" <<<"$staged")" ]; then
		printf 'lint-versions: note: %s also has other unstaged changes -- git add -p to stage only the version lines, unless you mean to commit those too.\n' "$LV_FILE" >&2
	fi
	printf 'lint-versions: %s in %s is not staged -- git add %s and commit again (for git commit <paths>, include it in the paths too).\n' \
		"$pairs" "$LV_FILE" "$LV_NAME" >&2
	return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
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
		# An unknown tool would parse as empty on both sides and read as
		# "unchanged" -- an error, so it must exit 2, not 1.
		case "${2:-}" in
		shellcheck | shfmt | ruff) ;;
		*)
			printf 'usage: %s changed <shellcheck|shfmt|ruff>\n' "${0##*/}" >&2
			exit 2
			;;
		esac
		staged=$(lv_get_git "$2" "") || exit 2
		head=$(lv_get_git "$2" HEAD) || exit 2
		[ "$staged" != "$head" ]
		;;
	*)
		printf 'usage: %s get <tool> | changed <tool>\n' "${0##*/}" >&2
		exit 2
		;;
	esac
fi
