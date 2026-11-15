#!/usr/bin/env bash
# Give root filtered, root-owned copies of the invoking user's GTK appearance
# settings so pkexec'd GTK apps (GParted) match, and list/set/pick GTK themes.
# Design and threat model: docs/gparted-root-theme-fix.md.
set -euo pipefail

PROG="${0##*/}"
KARTIK_HOME="${KARTIK_HOME:-/home/kartik}"
ROOT_HOME="${ROOT_HOME:-/root}"
MODE="apply"
THEME_NAME=""
THEME_DIRS=(
	"$KARTIK_HOME/.themes"
	"$KARTIK_HOME/.local/share/themes"
	"/usr/local/share/themes"
	"/usr/share/themes"
)

usage() {
	cat <<EOF
Usage: $PROG [--apply | --check | --list | --set THEME | --pick | -h|--help]

  --apply      (default) Write root-owned, filtered copies of $KARTIK_HOME's GTK
               appearance settings under $ROOT_HOME. Needs root (re-runs via
               sudo). Themes are not copied; a user-local one gets a NOTE.
  --check      Report drift between root's copies and what --apply would write.
               Needs root. Exits 1 on drift or an unsafe path.
  --list       List installed GTK themes found under:
$(printf '                 %s\n' "${THEME_DIRS[@]}")
  --set THEME  Set THEME as kartik's GTK theme (gtk-3.0, gtk-4.0, .gtkrc-2.0),
               then run --apply for root apps to follow.
  --pick       Same as --set, but choose the theme from a whiptail menu.
  -h --help    Show this help.
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	usage >&2
	exit 2
}

abort() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--apply | --check | --list | --pick)
		MODE="${1#--}"
		shift
		;;
	--set)
		[ "$#" -ge 2 ] || usage_error "--set requires a theme name"
		MODE="set"
		THEME_NAME="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) usage_error "unknown argument: $1" ;;
	esac
done

[ "$MODE" = check ] || [ "$MODE" = apply ] || [ -d "$KARTIK_HOME" ] || abort "$KARTIK_HOME does not exist"

list_themes() {
	local dir entry
	for dir in "${THEME_DIRS[@]}"; do
		for entry in "$dir"/*/; do
			[ -d "${entry}gtk-2.0" ] || [ -d "${entry}gtk-3.0" ] || [ -d "${entry}gtk-4.0" ] || continue
			basename "$entry"
		done
	done | sort -u
}

current_theme() {
	local f="$KARTIK_HOME/.config/gtk-3.0/settings.ini"
	[ -f "$f" ] || return 0
	sed -n 's/^gtk-theme-name=//p' "$f" | head -n1
}

# Never write through a dotfile symlink that leaves the user's home (e.g. to /etc/sudoers).
validate_kv_target() {
	local file="$1" real home_real
	[ -f "$file" ] || return 2
	real="$(realpath -e -- "$file" 2>/dev/null)" || {
		printf '%s: %s could not be resolved; refusing\n' "$PROG" "$file" >&2
		return 1
	}
	home_real="$(realpath -e -- "$KARTIK_HOME" 2>/dev/null)" || home_real="$KARTIK_HOME"
	case "$real" in
	"$home_real"/*) ;;
	*)
		printf '%s: %s resolves to %s, outside %s; refusing to write through it\n' \
			"$PROG" "$file" "$real" "$KARTIK_HOME" >&2
		return 1
		;;
	esac
	if [ "$(stat -c %u -- "$real")" != "$(id -u)" ]; then
		printf '%s: %s resolves to %s, which you don'"'"'t own; refusing to write through it\n' \
			"$PROG" "$file" "$real" >&2
		return 1
	fi
	if [ ! -w "$(dirname -- "$real")" ]; then
		printf '%s: %s resolves to %s, in a directory you can'"'"'t write; refusing\n' \
			"$PROG" "$file" "$real" >&2
		return 1
	fi
	printf '%s' "$real"
}

write_kv() {
	local file="$1" key="$2" value="$3" quoted="$4" tmp
	tmp="$(mktemp "${file}.XXXXXX")" || return 1
	if chmod --reference="$file" -- "$tmp" &&
		{ chown --reference="$file" -- "$tmp" 2>/dev/null || true; } &&
		awk -v k="$key" -v v="$value" -v q="$quoted" '
		BEGIN { if (q == "1") v = "\"" v "\"" }
		$0 ~ "^" k "=" { print k "=" v; done = 1; next }
		{ print }
		END { if (!done) print k "=" v }
	' "$file" >"$tmp"; then
		mv -- "$tmp" "$file"
		return
	fi
	rm -f -- "$tmp"
	return 1
}

apply_theme() {
	local name="$1" t found=0 i st fatal=0 failed=0 wrote=0
	local -a available=() ok=() reals=() quoted=(0 0 1) files=(
		"$KARTIK_HOME/.config/gtk-3.0/settings.ini"
		"$KARTIK_HOME/.config/gtk-4.0/settings.ini"
		"$KARTIK_HOME/.gtkrc-2.0"
	)
	mapfile -t available < <(list_themes)
	for t in "${available[@]}"; do
		[ "$t" != "$name" ] || found=1
	done
	if [ "$found" -ne 1 ]; then
		printf '%s: no installed theme named %s\n' "$PROG" "$name" >&2
		printf 'installed themes:\n' >&2
		printf '  %s\n' "${available[@]}" >&2
		exit 1
	fi
	for i in "${!files[@]}"; do
		st=0
		reals[i]="$(validate_kv_target "${files[i]}")" || st=$?
		case "$st" in
		0) ok+=("$i") ;;
		2) printf '%s: %s not found, skipping\n' "$PROG" "${files[i]}" >&2 ;;
		*) fatal=1 ;;
		esac
	done
	[ "$fatal" -eq 0 ] || abort "a target GTK settings file is unsafe (see above); changed nothing"
	[ "${#ok[@]}" -ne 0 ] || abort "none of the GTK settings files exist under $KARTIK_HOME; nothing set"
	for i in "${ok[@]}"; do
		if write_kv "${reals[i]}" gtk-theme-name "$name" "${quoted[i]}"; then
			printf '  gtk-theme-name=%s written to %s\n' "$name" "${files[i]}"
			wrote=$((wrote + 1))
		else
			printf '%s: failed to write %s\n' "$PROG" "${files[i]}" >&2
			failed=1
		fi
	done
	printf 'gtk-theme-name set to %s in %d file(s).\n' "$name" "$wrote"
	printf 'Root keeps its own copies (docs/gparted-root-theme-fix.md), so root apps such as GParted still use the old theme until you run:\n  pkexec %q --apply\n' "$(realpath -e -- "$0")"
	[ "$failed" -eq 0 ] || exit 1
}

pick_theme() {
	local items=() name current tag
	current="$(current_theme)"
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		tag=""
		[ "$name" != "$current" ] || tag="(current)"
		items+=("$name" "$tag")
	done < <(list_themes)
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No installed GTK themes found under:\n${THEME_DIRS[*]}" 12 70
		return 1
	fi
	wt --menu "Choose a GTK theme" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

if [ "$EUID" -eq 0 ] && { [ "$MODE" = set ] || [ "$MODE" = pick ]; }; then
	printf '%s: --%s rewrites the invoking user'"'"'s GTK config; don'"'"'t run it as root. Run it as that user, then "pkexec %q --apply" to refresh root'"'"'s copies.\n' \
		"$PROG" "$MODE" "$(realpath -e -- "$0")" >&2
	exit 1
fi

case "$MODE" in
list)
	current="$(current_theme)"
	found_any=0
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		found_any=1
		[ "$name" != "$current" ] || printf '* %s (current)\n' "$name"
		[ "$name" = "$current" ] || printf '  %s\n' "$name"
	done < <(list_themes)
	[ "$found_any" -eq 0 ] || exit 0
	printf 'no installed GTK themes found under: %s\n' "${THEME_DIRS[*]}" >&2
	exit 1
	;;
pick)
	tui_lib="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/tui.sh"
	if [ ! -r "$tui_lib" ]; then
		printf 'error: %s is missing; run %s from the repo checkout, or keep scripts/lib/ beside it\n' "$tui_lib" "${0##*/}" >&2
		exit 1
	fi
	# shellcheck source=/dev/null
	. "$tui_lib"
	command -v whiptail >/dev/null 2>&1 || abort "--pick needs whiptail (not found on PATH)"
	THEME_NAME="$(pick_theme)" || exit 0
	[ -n "$THEME_NAME" ] || exit 0
	;;
esac
if [ "$MODE" = set ] || [ "$MODE" = pick ]; then
	apply_theme "$THEME_NAME"
	exit 0
fi

escalate() {
	[ -z "${SYNC_ROOT_GTK_ESCALATED:-}" ] || abort "still not root after sudo"
	local self test_env=()
	self="$(realpath -e -- "$0")"
	if ! command -v sudo >/dev/null 2>&1; then
		printf '%s: --%s needs root and sudo is not on PATH; run it as root:\n  pkexec %q --%s\n' \
			"$PROG" "$MODE" "$self" "$MODE" >&2
		exit 1
	fi
	# sudo resets the environment: forward the test overrides only when asked, never a stale export.
	if [ "${SYNC_ROOT_GTK_TEST_HOME:-}" = 1 ]; then
		test_env=(KARTIK_HOME="$KARTIK_HOME" ROOT_HOME="$ROOT_HOME" SYNC_ROOT_GTK_TEST_HOME=1)
	fi
	exec sudo -- env SYNC_ROOT_GTK_ESCALATED=1 "${test_env[@]}" bash "$self" "--$MODE"
}
[ "$EUID" -eq 0 ] || escalate

writable_by_nonroot() {
	local p="$1"
	until [ -n "$(find "$p" -maxdepth 0 \( ! -user 0 -o \( -perm /022 ! -perm -1000 \) \) -print 2>/dev/null)" ]; do
		[ "$p" != / ] || return 0
		p="$(dirname -- "$p")"
	done
	printf '%s\n' "$p"
}

self_path="$(realpath -e -- "${BASH_SOURCE[0]}")"
self_weak="$(writable_by_nonroot "$self_path")"
if [ -n "$self_weak" ]; then
	printf '%s: WARNING: running as root from %s, but %s can be modified by a non-root user, so that user effectively controls what runs as root. For a root-owned copy:\n  pkexec install -m 0755 -o root -g root %q /usr/local/sbin/sync-root-gtk-theme\n  pkexec /usr/local/sbin/sync-root-gtk-theme --%s\n' \
		"$PROG" "$self_path" "$self_weak" "$self_path" "$MODE" >&2
fi

if [ "${SYNC_ROOT_GTK_TEST_HOME:-}" = 1 ]; then
	printf '%s: WARNING: TEST MODE (SYNC_ROOT_GTK_TEST_HOME=1): ROOT_HOME=%s and KARTIK_HOME=%s are not checked against the passwd database. Never set this for a real run.\n' \
		"$PROG" "$ROOT_HOME" "$KARTIK_HOME" >&2
else
	root_pw_home="$(getent passwd 0 | cut -d: -f6)"
	root_home_real="$(realpath -e -- "$ROOT_HOME" 2>/dev/null)" || root_home_real="$ROOT_HOME"
	root_pw_home_real="$(realpath -e -- "$root_pw_home" 2>/dev/null)" || root_pw_home_real="$root_pw_home"
	[ -n "$root_pw_home" ] && [ "$root_home_real" = "$root_pw_home_real" ] ||
		abort "ROOT_HOME ($ROOT_HOME) is not root's passwd home (${root_pw_home:-unknown}); refusing. Unset ROOT_HOME for a real run."
fi
[ -d "$ROOT_HOME" ] || abort "$ROOT_HOME does not exist"
umask 022

# The target is the invoking user, never uid 0: as root, the read-as-user step would read anything.
target_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
case "$target_uid" in
'') abort "can't tell whose GTK settings to copy: run --$MODE via pkexec or sudo from that user's session (PKEXEC_UID and SUDO_UID are both unset)" ;;
*[!0-9]*) abort "invoking uid $target_uid is not a number" ;;
0) abort "refusing to copy settings for uid 0: run --$MODE via pkexec or sudo from the desktop user's session, not from root" ;;
esac
target_pw="$(getent passwd "$target_uid")" || abort "uid $target_uid has no passwd entry"
IFS=: read -r KARTIK_USER _ KARTIK_UID KARTIK_GID _ target_home _ <<<"$target_pw"
[ "$KARTIK_UID" = "$target_uid" ] && [ "$KARTIK_UID" != 0 ] && [ -n "$KARTIK_USER" ] ||
	abort "passwd entry for uid $target_uid is unusable"
[ "${SYNC_ROOT_GTK_TEST_HOME:-}" = 1 ] || KARTIK_HOME="$target_home"
KARTIK_REAL="$(realpath -e -- "$KARTIK_HOME" 2>/dev/null)" && [ -d "$KARTIK_REAL" ] ||
	abort "$KARTIK_USER's home $KARTIK_HOME is not an existing directory"
command -v setpriv >/dev/null 2>&1 || abort "setpriv (util-linux) is needed to read $KARTIK_USER's files with $KARTIK_USER's privileges"

# Read the user's files only through this, so a swapped-in symlink can't reach root-only files.
as_kartik() {
	setpriv --reuid="$KARTIK_UID" --regid="$KARTIK_GID" --init-groups -- "$@"
}

# Appearance-only allowlist: never add a key whose value can name a module, file or directory.
APPEARANCE_KEYS="gtk-theme-name gtk-icon-theme-name gtk-cursor-theme-name
gtk-cursor-theme-size gtk-font-name gtk-application-prefer-dark-theme
gtk-xft-antialias gtk-xft-hinting gtk-xft-hintstyle gtk-xft-rgba gtk-xft-dpi
gtk-decoration-layout gtk-enable-animations gtk-button-images gtk-menu-images
gtk-toolbar-style"
MANAGED_HEADER="# Managed by sync-root-gtk-theme.sh"
PENDING=""
trap '[ -z "$PENDING" ] || rm -rf -- "$PENDING"' EXIT
drift=0
failed=0

filter_settings() {
	local fmt="$1" src="$2" verbose="$3"
	printf '%s: appearance keys copied from\n# %s. Re-run --apply to refresh; edits here are overwritten.\n' \
		"$MANAGED_HEADER" "$src"
	[ "$fmt" != ini ] || printf '[Settings]\n'
	awk -v fmt="$fmt" -v keys="$APPEARANCE_KEYS" -v verbose="$verbose" -v prog="$PROG" -v src="$src" '
	function drop(what) {
		if (what in seen) return
		seen[what] = 1
		dropped = dropped (dropped == "" ? "" : ", ") what
	}
	BEGIN {
		n = split(keys, list, /[ \n]+/)
		for (i = 1; i <= n; i++) allow[list[i]] = 1
		in_settings = (fmt == "rc")
	}
	{
		line = $0
		sub(/^[ \t]+/, "", line)
		sub(/[ \t\r]+$/, "", line)
		if (line == "" || line ~ /^#/) next
		if (fmt == "ini" && line ~ /^\[.*\]$/) { in_settings = (line == "[Settings]"); next }
		if (fmt == "ini" && !in_settings) { drop("lines outside [Settings]"); next }
	}
	fmt != "ini" {
		at_top = (depth == 0)
		bare = line
		gsub(/"[^"]*"/, "", bare)
		opens = gsub(/\{/, "", bare)
		closes = gsub(/\}/, "", bare)
		depth += opens - closes
		if (depth < 0) depth = 0
		if (!at_top || opens || closes) { drop("style/binding blocks"); next }
	}
	{
		eq = index(line, "=")
		if (eq == 0) { drop("other statements (include, module_path, ...)"); next }
		key = substr(line, 1, eq - 1)
		sub(/[ \t]+$/, "", key)
		value = substr(line, eq + 1)
		sub(/^[ \t]+/, "", value)
		if (!(key in allow)) { drop(key); next }
		quoted = (fmt == "rc" && value ~ /^".*"$/)
		if (quoted) value = substr(value, 2, length(value) - 2)
		if (value !~ /^[A-Za-z0-9 ._+,:@-]*$/ || value ~ /\.\./) { drop(key " (unsafe value)"); next }
		if (fmt == "rc" && !quoted && value !~ /^(-?[0-9]+|[A-Za-z_][A-Za-z0-9_]*)$/) { drop(key " (unquoted value)"); next }
		print key "=" (quoted ? "\"" value "\"" : value)
	}
	END {
		if (verbose && dropped != "")
			printf "%s: from %s, left out: %s\n", prog, src, dropped > "/dev/stderr"
	}
	'
}

is_managed() {
	local first=""
	[ -f "$1" ] || return 1
	IFS= read -r first <"$1" || true
	[[ $first == "$MANAGED_HEADER"* ]]
}

ensure_root_dir() {
	local path="$ROOT_HOME" rest="${1#"$ROOT_HOME"}" part
	while [ -n "$rest" ]; do
		rest="${rest#/}"
		part="${rest%%/*}"
		rest="${rest#"$part"}"
		path="$path/$part"
		if [ -L "$path" ]; then
			printf '%s: refusing to write under %s: it is a symlink (-> %s); move it aside and re-run\n' \
				"$PROG" "$path" "$(readlink -- "$path")" >&2
			return 1
		fi
		[ -d "$path" ] || mkdir -m 0755 -- "$path" || return 1
	done
}

put_in_place() {
	local new="$1" dest="$2" backup
	if [ -L "$dest" ]; then
		printf 'replacing symlink %s -> %s\n' "$dest" "$(readlink -- "$dest")"
		rm -f -- "$dest" || return 1
	elif [ -e "$dest" ] && ! { [ -f "$dest" ] && [ -f "$new" ] && is_managed "$dest"; }; then
		backup="${dest}.bak-$(date +%s)"
		mv -T -- "$dest" "$backup" || return 1
		printf 'backed up existing %s -> %s\n' "$dest" "$backup"
	fi
	mv -T -- "$new" "$dest"
}

remove_stale() {
	local dest="$1" src="$2" why="$3"
	if [ -L "$dest" ]; then
		rm -f -- "$dest" || return 1
		printf 'removed symlink %s (%s %s)\n' "$dest" "$src" "$why"
	elif [ -e "$dest" ] && is_managed "$dest"; then
		rm -rf -- "$dest" || return 1
		printf 'removed %s (%s %s)\n' "$dest" "$src" "$why"
	else
		printf 'skip    %s (%s %s)\n' "$dest" "$src" "$why"
	fi
}

source_file_state() {
	local real owner
	[ -e "$1" ] || [ -L "$1" ] || return 1
	real="$(realpath -e -- "$1" 2>/dev/null)" || return 2
	[ -f "$real" ] && [[ $real == "$KARTIK_REAL"/* ]] || return 2
	owner="$(stat -c %u -- "$real" 2>/dev/null)" || return 2
	[ "$owner" = "$KARTIK_UID" ] || return 2
}

source_file_reason() {
	if [ "$1" -eq 2 ]; then
		printf 'unsafe source (symlink outside %s, not a regular file, or not owned by the user)' "$KARTIK_HOME"
	else
		printf 'does not exist'
	fi
}

report_symlinked() {
	local path="$1" fix="--apply replaces it with a root-owned file"
	while [ "$path" != "$ROOT_HOME" ] && [ "$path" != / ] && [ "$path" != . ]; do
		if [ -L "$path" ]; then
			printf 'UNSAFE  %s is a symlink (-> %s); %s\n' "$path" "$(readlink -- "$path")" "$fix"
			drift=1
			return 0
		fi
		fix="--apply won't write through it; move it aside by hand"
		path="$(dirname -- "$path")"
	done
	return 1
}

report_unsafe_perms() {
	local bad
	bad="$(find "$1" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>&1)" ||
		bad="${bad:-$1 (find failed)}"
	[ -n "$bad" ] || return 1
	printf 'UNSAFE  %s: %s is not root-owned or is group/world-writable\n' "$1" "$bad"
	drift=1
}

is_appearance_dir() {
	local kind="$1" p="$2"
	shift 2
	if [ "$kind" = themes ]; then
		"$@" test -d "$p/gtk-2.0" || "$@" test -d "$p/gtk-3.0" || "$@" test -d "$p/gtk-4.0"
	else
		"$@" test -d "$p"
	fi
}

note_if_user_local() {
	local label="$1" name="$2" kind="$3" d found=""
	[ -n "$name" ] || return 0
	case "$name" in *[[:cntrl:]/]*) return 0 ;; esac
	for d in "/usr/share/$kind" "/usr/local/share/$kind"; do
		is_appearance_dir "$kind" "$d/$name" && return 0
	done
	for d in "$KARTIK_HOME/.$kind" "$KARTIK_HOME/.local/share/$kind"; do
		is_appearance_dir "$kind" "$d/$name" as_kartik && found="$d/$name" && break
	done
	[ -n "$found" ] || return 0
	printf '%s: NOTE: the %s %q is user-local (%q), so root GTK apps fall back to the default. Root can'"'"'t safely use a tree your account can write, so this script copies nothing from it and prints no install command. Install it system-wide by a route you trust: the distro or AUR package if one exists, or a manual copy into %s that you have reviewed.\n' \
		"$PROG" "$label" "$name" "$found" "/usr/local/share/$kind" >&2
}

warn_user_local() {
	local f="$KARTIK_HOME/.config/gtk-3.0/settings.ini" content
	source_file_state "$f" || return 0
	content="$(as_kartik cat -- "$f" 2>/dev/null)" || return 0
	note_if_user_local "GTK theme" "$(printf '%s\n' "$content" | sed -n 's/^gtk-theme-name=//p' | head -n1)" themes
	note_if_user_local "icon theme" "$(printf '%s\n' "$content" | sed -n 's/^gtk-icon-theme-name=//p' | head -n1)" icons
	note_if_user_local "cursor theme" "$(printf '%s\n' "$content" | sed -n 's/^gtk-cursor-theme-name=//p' | head -n1)" icons
}

apply_file() {
	local fmt="$1" dest="$2" src="$3" state=0 parent tmp content
	parent="$(dirname -- "$dest")"
	ensure_root_dir "$parent" || return 1
	source_file_state "$src" || state=$?
	if [ "$state" -ne 0 ]; then
		remove_stale "$dest" "$src" "$(source_file_reason "$state")"
		return
	fi
	if ! content="$(as_kartik cat -- "$src" 2>/dev/null)"; then
		remove_stale "$dest" "$src" "could not be read as $KARTIK_USER"
		return
	fi
	tmp="$(mktemp -- "$parent/.${dest##*/}.new.XXXXXX")" || return 1
	PENDING="$tmp"
	printf '%s\n' "$content" | filter_settings "$fmt" "$src" 1 >"$tmp" || return 1
	chown 0:0 -- "$tmp" || return 1
	chmod 0644 -- "$tmp" || return 1
	put_in_place "$tmp" "$dest" || return 1
	PENDING=""
	printf 'wrote   %s (appearance keys from %s)\n' "$dest" "$src"
}

check_file() {
	local fmt="$1" dest="$2" src="$3" state=0 content
	report_symlinked "$dest" && return 0
	source_file_state "$src" || state=$?
	if [ "$state" -ne 0 ] && [ -e "$dest" ] && is_managed "$dest"; then
		printf 'STALE   %s (%s %s; --apply removes it)\n' "$dest" "$src" "$(source_file_reason "$state")"
		drift=1
		return 0
	fi
	if [ "$state" -ne 0 ]; then
		printf 'skip    %s (%s %s)\n' "$dest" "$src" "$(source_file_reason "$state")"
		return 0
	fi
	if [ ! -f "$dest" ]; then
		printf 'DRIFT   %s (missing or not a regular file)\n' "$dest"
		drift=1
		return 0
	fi
	report_unsafe_perms "$dest" && return 0
	if ! content="$(as_kartik cat -- "$src" 2>/dev/null)"; then
		printf 'skip    %s (%s could not be read as %s)\n' "$dest" "$src" "$KARTIK_USER"
		return 0
	fi
	if printf '%s\n' "$content" | filter_settings "$fmt" "$src" 0 | cmp -s -- - "$dest"; then
		printf 'ok      %s (matches %s)\n' "$dest" "$src"
	else
		printf 'DRIFT   %s (differs from the filtered %s)\n' "$dest" "$src"
		drift=1
	fi
}

TARGET_FILES=(
	rc "$ROOT_HOME/.gtkrc-2.0" "$KARTIK_HOME/.gtkrc-2.0"
	ini "$ROOT_HOME/.config/gtk-3.0/settings.ini" "$KARTIK_HOME/.config/gtk-3.0/settings.ini"
	ini "$ROOT_HOME/.config/gtk-4.0/settings.ini" "$KARTIK_HOME/.config/gtk-4.0/settings.ini"
)
LEGACY_DIRS=(
	theme "$ROOT_HOME/.themes"
	theme "$ROOT_HOME/.local/share/themes"
	icon "$ROOT_HOME/.icons"
	icon "$ROOT_HOME/.local/share/icons"
)
LEGACY_MARKER=".sync-root-gtk-theme"

in_kartik_home() {
	[[ $1 == "$KARTIK_HOME" || $1 == "$KARTIK_HOME"/* || $1 == "$KARTIK_REAL" || $1 == "$KARTIK_REAL"/* ]]
}

links_into_home() {
	local raw lex full
	raw="$(readlink -- "$1")" || return 1
	[[ $raw == /* ]] || raw="$(dirname -- "$1")/$raw"
	lex="$(realpath -m -s -- "$raw" 2>/dev/null)" || lex=""
	full="$(realpath -m -- "$1" 2>/dev/null)" || full=""
	{ [ -n "$lex" ] && in_kartik_home "$lex"; } || { [ -n "$full" ] && in_kartik_home "$full"; }
}

symlinked_ancestor() {
	local path highest=""
	path="$(dirname -- "$1")"
	while [ "$path" != "$ROOT_HOME" ] && [ "$path" != / ] && [ "$path" != . ]; do
		[ -L "$path" ] && highest="$path"
		path="$(dirname -- "$path")"
	done
	printf '%s' "$highest"
}

# Shared by --check and --apply. Never recurse into or delete a directory: unlink or rename only.
classify_legacy() {
	local kind="$1" path="$2"
	if [ -n "$(symlinked_ancestor "$path")" ]; then
		echo ancestor
	elif [ -L "$path" ] && { [ "$kind" != icon ] || links_into_home "$path"; }; then
		echo symlink
	elif [ -L "$path" ] || [ ! -e "$path" ] || { [ "$kind" = icon ] && [ ! -f "$path/$LEGACY_MARKER" ]; }; then
		echo none
	else
		echo backup
	fi
}

check_legacy() {
	local path="$2" anc
	case "$(classify_legacy "$1" "$path")" in
	none) return 0 ;;
	symlink)
		printf 'UNSAFE  %s is a legacy symlink (-> %s) into a user-writable theme tree; --apply removes the link\n' \
			"$path" "$(readlink -- "$path")"
		;;
	ancestor)
		anc="$(symlinked_ancestor "$path")"
		printf 'UNSAFE  %s sits under the symlink %s (-> %s); --apply will not touch it -- remove %s by hand if it is safe\n' \
			"$path" "$anc" "$(readlink -- "$anc")" "$anc"
		;;
	backup)
		printf 'LEGACY  %s is a leftover /root appearance dir root GTK would read; --apply moves it aside to *.bak-<epoch>\n' "$path"
		;;
	esac
	drift=1
}

apply_legacy() {
	local path="$2" anc backup
	case "$(classify_legacy "$1" "$path")" in
	none) return 0 ;;
	symlink)
		rm -f -- "$path" || return 1
		printf 'removed legacy symlink %s\n' "$path"
		;;
	ancestor)
		anc="$(symlinked_ancestor "$path")"
		printf '%s: not touching %s: its ancestor %s is a symlink (-> %s) into kartik'"'"'s tree. Remove %s by hand if it is safe, then re-run.\n' \
			"$PROG" "$path" "$anc" "$(readlink -- "$anc")" "$anc" >&2
		return 1
		;;
	backup)
		backup="${path}.bak-$(date +%s)"
		mv -T -- "$path" "$backup" || return 1
		printf 'backed up %s -> %s (leftover /root appearance dir; review it)\n' "$path" "$backup"
		;;
	esac
	return 0
}

target_failed() {
	failed=1
	[ -z "$PENDING" ] || rm -rf -- "$PENDING"
	PENDING=""
}

run_all() {
	local i
	for ((i = 0; i < ${#TARGET_FILES[@]}; i += 3)); do
		"${1}_file" "${TARGET_FILES[@]:i:3}" || target_failed
	done
	for ((i = 0; i < ${#LEGACY_DIRS[@]}; i += 2)); do
		"${1}_legacy" "${LEGACY_DIRS[@]:i:2}" || target_failed
	done
}

warn_user_local
[ "$MODE" = check ] || run_all apply
[ "$MODE" = check ] || echo "--- verify ---"
run_all check
if [ "$failed" -ne 0 ] || [ "$drift" -ne 0 ]; then
	exit 1
fi
