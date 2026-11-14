#!/usr/bin/env bash
# sync-root-gtk-theme.sh — give root a filtered, root-owned copy of kartik's
# GTK appearance *settings*, so GParted (and any other pkexec/su-elevated GTK
# app) renders kartik's look. Also discovers installed GTK themes the way
# lxappearance/nwg-look do (scanning the standard theme directories for a
# gtk-2.0/gtk-3.0/gtk-4.0 subdirectory) and can set one as kartik's active
# theme directly, whiptail picker included.
#
# Root cause and history: docs/gparted-root-theme-fix.md. Short version:
# pkexec runs GTK apps as root with $HOME=/root, so root reads its own GTK
# config, not kartik's. Earlier versions symlinked root's config and theme
# directories to kartik's; a later version copied the themes and icon trees
# too. Both let code running as kartik pick code for root to load, and each
# review pass found a new root-side bug in the copy machinery (writing the
# marker through a planted symlink, deleting kartik's dir through a symlinked
# ancestor, a lexical link rule defeated by a newline). Copying nothing from
# a user-writable tree is the simple, safe design:
#
#   - Settings files (gtk-3.0/gtk-4.0 settings.ini, .gtkrc-2.0) are filtered
#     to an appearance-key allowlist (no gtk-modules, no path-valued keys,
#     no GTK 2 include/engine/module statements) and written as root-owned
#     0644 files. This is the only thing copied.
#   - GTK themes, icon themes and cursor themes are NOT copied. Root's
#     settings still name them; GTK uses them only if they're installed
#     system-wide (under /usr/share or /usr/local/share), else it falls back
#     to the default. When a configured one lives only under kartik's
#     user-local dirs, --apply and --check print a NOTE naming it, with no
#     install command: root can't safely consume a user-writable tree, so
#     kartik installs it system-wide by a route he trusts (the distro or
#     AUR package, or a manual copy he has reviewed).
#
# Every READ of a file under kartik's home is done with kartik's privileges
# (setpriv to his uid/gid/groups), never as root, so a symlink swapped in
# under kartik's config can only ever expose a file kartik can already read
# -- it can't make root read /root.
#
# Copies don't follow kartik's later edits, so re-run --apply after a theme
# switch (--set/--pick print the command). --check compares the filtered
# settings it would write against what's in /root, so drift still shows.
#
# --list/--set/--pick only touch kartik's own files and need no root.
# --check/--apply need root, run via pkexec (or sudo) from kartik's session:
# the user whose settings are copied is taken from PKEXEC_UID / SUDO_UID,
# never assumed, and it must not be root.
#
# Trust: whatever runs as root must not be writable by anyone else. The root
# path executes only this file (lib/tui.sh is sourced solely by --pick, which
# runs as kartik). A copy inside kartik's repo is kartik-writable, so running
# it via pkexec trusts kartik's account with root -- the script warns about
# that every time. To remove the warning, install a root-owned copy and run
# that instead:
#   pkexec install -m 0755 -o root -g root \
#     /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh \
#     /usr/local/sbin/sync-root-gtk-theme
#   pkexec /usr/local/sbin/sync-root-gtk-theme --apply
# (re-install after changing the repo copy). Running the repo copy directly,
#   pkexec /home/kartik/claude-agent-workspace/scripts/sync-root-gtk-theme.sh --apply
# still works; it warns rather than refuses.
#
# Idempotent. A file or directory at a target path that this script didn't
# write is backed up (*.bak-<epoch>), not deleted, before being replaced.
#
# KARTIK_HOME overrides /home/kartik for --list/--set/--pick. For --check
# and --apply, the user's home is always taken from the target user's passwd
# entry and root's from uid 0's; KARTIK_HOME and ROOT_HOME override them
# only together with SYNC_ROOT_GTK_TEST_HOME=1, for tests against scratch
# directories (the script then warns loudly).

set -euo pipefail

PROG="${0##*/}"

KARTIK_HOME="${KARTIK_HOME:-/home/kartik}"
ROOT_HOME="${ROOT_HOME:-/root}"
MODE="apply"
THEME_NAME=""

# Same search order lxappearance/nwg-look use: user-local first, then
# system-wide. /usr/local/share/themes rarely exists on Debian but is
# checked for completeness.
THEME_DIRS=(
	"$KARTIK_HOME/.themes"
	"$KARTIK_HOME/.local/share/themes"
	"/usr/local/share/themes"
	"/usr/share/themes"
)

usage() {
	cat <<EOF
Usage: $PROG [--apply | --check | --list | --set THEME | --pick | -h|--help]

  --apply      (also the default, with no flags) Write root-owned, filtered
               copies of \$KARTIK_HOME's ($KARTIK_HOME) GTK appearance
               settings under \$ROOT_HOME ($ROOT_HOME). Themes/icons/cursors
               are not copied; a user-local one is reported (NOTE) so it can
               be installed system-wide. Needs root; re-runs itself under
               sudo if started as kartik.
  --check      Report whether root's settings copies match what --apply would
               write, without changing anything. Needs root. Exits 1 on any
               drift or unsafe path (such as a leftover symlink).
  --list       List installed GTK themes found under:
$(printf '                 %s\n' "${THEME_DIRS[@]}")
               No root needed.
  --set THEME  Set THEME as kartik's active GTK theme (gtk-3.0, gtk-4.0,
               and .gtkrc-2.0). No root needed. Root keeps its own settings
               copies, so run --apply afterwards for root apps to follow.
  --pick       Same as --set, but choose the theme from a whiptail menu.
  -h --help    Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--apply)
		MODE="apply"
		shift
		;;
	--check)
		MODE="check"
		shift
		;;
	--list)
		MODE="list"
		shift
		;;
	--pick)
		MODE="pick"
		shift
		;;
	--set)
		MODE="set"
		shift
		if [ "$#" -eq 0 ]; then
			printf '%s: --set requires a theme name\n' "$PROG" >&2
			usage >&2
			exit 2
		fi
		THEME_NAME="$1"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

# --check/--apply take the home from the passwd database instead (below).
if [ "$MODE" != check ] && [ "$MODE" != apply ] && [ ! -d "$KARTIK_HOME" ]; then
	printf '%s: %s does not exist\n' "$PROG" "$KARTIK_HOME" >&2
	exit 1
fi

# --- theme discovery / setting (no root needed for any of this) -----------

# One installed theme name per line, deduped, across THEME_DIRS. A directory
# only counts as a GTK theme (not, say, a same-named Metacity/xfwm4-only
# variant, which some theme packages ship as sibling "-hdpi"/"-xhdpi" dirs
# with no gtk-*.0 subdir at all) if it has a gtk-2.0, gtk-3.0, or gtk-4.0
# subdirectory.
list_themes() {
	local dir entry
	for dir in "${THEME_DIRS[@]}"; do
		[ -d "$dir" ] || continue
		for entry in "$dir"/*/; do
			[ -d "$entry" ] || continue
			if [ -d "${entry}gtk-2.0" ] || [ -d "${entry}gtk-3.0" ] || [ -d "${entry}gtk-4.0" ]; then
				basename "$entry"
			fi
		done
	done | sort -u
}

current_theme() {
	local f="$KARTIK_HOME/.config/gtk-3.0/settings.ini"
	[ -f "$f" ] || return 0
	sed -n 's/^gtk-theme-name=//p' "$f" | head -n1
}

# Resolve settings file $1 and decide whether it's safe to write. On stdout
# it echoes the resolved real path. Returns 0 (valid, path echoed), 2 (no
# such file -- skip it, nothing printed) or 1 (present but unsafe, reason on
# stderr). A symlinked dotfile is accepted only when it resolves inside the
# user's home, is theirs, and sits in a directory they can write; otherwise
# it's refused, so --set can never write through a link to a file like
# /etc/sudoers (set/pick also refuse root; this is defense in depth).
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

# Upsert key=value (or key="value" if quoted=1) in already-validated real
# file $1, preserving every other line. Writes via a same-directory temp
# file plus mv so a mid-write failure can't leave the config half-written,
# keeping the file's mode and owner (mktemp alone would leave it 0600).
write_kv() {
	local file="$1" key="$2" value="$3" quoted="$4" tmp
	tmp="$(mktemp "${file}.XXXXXX")" || return 1
	if ! chmod --reference="$file" -- "$tmp"; then
		rm -f -- "$tmp"
		return 1
	fi
	# Only matters when run as root on kartik's files; as kartik it's a no-op.
	chown --reference="$file" -- "$tmp" 2>/dev/null || true
	if awk -v k="$key" -v v="$value" -v q="$quoted" '
		BEGIN { done = 0 }
		$0 ~ "^" k "=" {
			if (q == "1") print k "=\"" v "\""
			else print k "=" v
			done = 1
			next
		}
		{ print }
		END {
			if (!done) {
				if (q == "1") print k "=\"" v "\""
				else print k "=" v
			}
		}
	' "$file" >"$tmp"; then
		mv -- "$tmp" "$file"
	else
		rm -f -- "$tmp"
		return 1
	fi
}

# Validate $1 against the discovered theme list, then set it as the theme.
# All three settings files are validated first; if any present one is unsafe,
# nothing is written. Then each is written and reported, and the run exits
# nonzero if any write failed -- never leaving the three disagreeing silently.
apply_theme() {
	local name="$1" t found=0 i st real present=0 fatal=0 failed=0 wrote=0
	local available=()
	local -a files=(
		"$KARTIK_HOME/.config/gtk-3.0/settings.ini"
		"$KARTIK_HOME/.config/gtk-4.0/settings.ini"
		"$KARTIK_HOME/.gtkrc-2.0"
	)
	local -a quoted=(0 0 1)
	local -a reals=() rq=() rfile=()

	mapfile -t available < <(list_themes)
	for t in "${available[@]}"; do
		if [ "$t" = "$name" ]; then
			found=1
			break
		fi
	done
	if [ "$found" -ne 1 ]; then
		printf '%s: no installed theme named %s\n' "$PROG" "$name" >&2
		printf 'installed themes:\n' >&2
		printf '  %s\n' "${available[@]}" >&2
		exit 1
	fi

	# Phase 1: validate every target. Change nothing if one is unsafe.
	for i in "${!files[@]}"; do
		st=0
		real="$(validate_kv_target "${files[i]}")" || st=$?
		case "$st" in
		0)
			reals+=("$real")
			rq+=("${quoted[i]}")
			rfile+=("${files[i]}")
			present=$((present + 1))
			;;
		2) printf '%s: %s not found, skipping\n' "$PROG" "${files[i]}" >&2 ;;
		*) fatal=1 ;;
		esac
	done
	if [ "$fatal" -ne 0 ]; then
		printf '%s: a target GTK settings file is unsafe (see above); changed nothing\n' "$PROG" >&2
		exit 1
	fi
	if [ "$present" -eq 0 ]; then
		printf '%s: none of the GTK settings files exist under %s; nothing set\n' "$PROG" "$KARTIK_HOME" >&2
		exit 1
	fi

	# Phase 2: write every validated target, reporting each.
	for i in "${!reals[@]}"; do
		if write_kv "${reals[i]}" gtk-theme-name "$name" "${rq[i]}"; then
			printf '  gtk-theme-name=%s written to %s\n' "$name" "${rfile[i]}"
			wrote=$((wrote + 1))
		else
			printf '%s: failed to write %s\n' "$PROG" "${rfile[i]}" >&2
			failed=1
		fi
	done

	printf 'gtk-theme-name set to %s in %d file(s).\n' "$name" "$wrote"
	printf 'Root keeps its own copies (docs/gparted-root-theme-fix.md), so root apps such as GParted still use the old theme until you run:\n  pkexec %q --apply\n' "$(realpath -e -- "$0")"
	[ "$failed" -eq 0 ] || exit 1
}

pick_theme() {
	local items=() name current
	current="$(current_theme)"
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		if [ "$name" = "$current" ]; then
			items+=("$name" "(current)")
		else
			items+=("$name" "")
		fi
	done < <(list_themes)
	if [ "${#items[@]}" -eq 0 ]; then
		wt --msgbox "No installed GTK themes found under:\n${THEME_DIRS[*]}" 12 70
		return 1
	fi
	wt --menu "Choose a GTK theme" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

case "$MODE" in
list)
	current="$(current_theme)"
	found_any=0
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		found_any=1
		if [ "$name" = "$current" ]; then
			printf '* %s (current)\n' "$name"
		else
			printf '  %s\n' "$name"
		fi
	done < <(list_themes)
	if [ "$found_any" -eq 0 ]; then
		printf 'no installed GTK themes found under: %s\n' "${THEME_DIRS[*]}" >&2
		exit 1
	fi
	exit 0
	;;
set)
	# A user-side command: it rewrites kartik's own GTK config. Run as root
	# (e.g. via sudo) it would rewrite root's, and worse, follow a symlinked
	# dotfile out to a root-only file -- so refuse and point at --apply.
	if [ "$EUID" -eq 0 ]; then
		printf '%s: --set rewrites the invoking user'"'"'s GTK config; don'"'"'t run it as root. Run it as that user, then "pkexec %q --apply" to refresh root'"'"'s copies.\n' \
			"$PROG" "$(realpath -e -- "$0")" >&2
		exit 1
	fi
	apply_theme "$THEME_NAME"
	exit 0
	;;
pick)
	if [ "$EUID" -eq 0 ]; then
		printf '%s: --pick rewrites the invoking user'"'"'s GTK config; don'"'"'t run it as root. Run it as that user, then "pkexec %q --apply" to refresh root'"'"'s copies.\n' \
			"$PROG" "$(realpath -e -- "$0")" >&2
		exit 1
	fi
	# The only path that shows dialogs, and it runs as kartik: lib/tui.sh's wt
	# sends display-only dialogs to /dev/tty, so pick_theme's "no themes" box
	# doesn't draw into $(...). Never sourced on a root path.
	tui_lib="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/tui.sh"
	if [ ! -r "$tui_lib" ]; then
		printf 'error: %s is missing; run %s from the repo checkout, or keep scripts/lib/ beside it\n' "$tui_lib" "${0##*/}" >&2
		exit 1
	fi
	# Linted on its own, so not followed here.
	# shellcheck source=/dev/null
	. "$tui_lib"
	command -v whiptail >/dev/null 2>&1 || {
		printf '%s: --pick needs whiptail (not found on PATH)\n' "$PROG" >&2
		exit 1
	}
	picked="$(pick_theme)" || exit 0
	[ -z "$picked" ] && exit 0
	apply_theme "$picked"
	exit 0
	;;
esac

# --- --check / --apply: everything below runs as root ---------------------

if [ "$EUID" -ne 0 ]; then
	if [ -n "${SYNC_ROOT_GTK_ESCALATED:-}" ]; then
		printf '%s: still not root after sudo\n' "$PROG" >&2
		exit 1
	fi
	self="$(realpath -e -- "$0")"
	if ! command -v sudo >/dev/null 2>&1; then
		printf '%s: --%s needs root and sudo is not on PATH; run it as root:\n  pkexec %q --%s\n' \
			"$PROG" "$MODE" "$self" "$MODE" >&2
		exit 1
	fi
	# sudo resets the environment. The root side takes both homes from the
	# passwd database, so forward the test-only overrides (KARTIK_HOME,
	# ROOT_HOME, SYNC_ROOT_GTK_TEST_HOME) only when the test flag is set on
	# purpose: a value left exported from a test session must not quietly
	# redirect a real run. If sudo can't escalate (wrong password, no TTY,
	# not in sudoers) it says so itself and exits nonzero.
	test_env=()
	if [ "${SYNC_ROOT_GTK_TEST_HOME:-}" = 1 ]; then
		test_env=(KARTIK_HOME="$KARTIK_HOME" ROOT_HOME="$ROOT_HOME" SYNC_ROOT_GTK_TEST_HOME=1)
	fi
	exec sudo -- env SYNC_ROOT_GTK_ESCALATED=1 "${test_env[@]}" bash "$self" "--$MODE"
fi

# Print the first path, from $1 up to /, that a non-root user could modify:
# one not owned by root, or group/other-writable without the sticky bit (a
# sticky root-owned dir like /tmp lets others add entries but not replace
# root's). Prints nothing if the whole chain is root-controlled. Metadata
# only, so it can be checked (and tested) without privileges.
writable_by_nonroot() {
	local p="$1"
	while :; do
		if [ -n "$(find "$p" -maxdepth 0 \( ! -user 0 -o \( -perm /022 ! -perm -1000 \) \) -print 2>/dev/null)" ]; then
			printf '%s\n' "$p"
			return 0
		fi
		[ "$p" = / ] && return 0
		p="$(dirname -- "$p")"
	done
}

# The root path runs this file and nothing else from kartik's tree (lib/tui.sh
# is --pick only). If a non-root user can change it, whoever controls that
# account controls what runs as root. That's inherent to running a script
# from a user's repo via pkexec, and it's the route Kartik uses today, so warn
# loudly instead of refusing; a root-owned install removes the warning.
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
	# A real run writes root's own home and nothing else: refuse a ROOT_HOME
	# (e.g. one exported from a test session) that isn't uid 0's passwd home.
	root_pw_home="$(getent passwd 0 | cut -d: -f6)"
	root_home_real="$(realpath -e -- "$ROOT_HOME" 2>/dev/null)" || root_home_real="$ROOT_HOME"
	root_pw_home_real="$(realpath -e -- "$root_pw_home" 2>/dev/null)" || root_pw_home_real="$root_pw_home"
	if [ -z "$root_pw_home" ] || [ "$root_home_real" != "$root_pw_home_real" ]; then
		printf '%s: ROOT_HOME (%s) is not root'"'"'s passwd home (%s); refusing. Unset ROOT_HOME for a real run.\n' \
			"$PROG" "$ROOT_HOME" "${root_pw_home:-unknown}" >&2
		exit 1
	fi
fi
if [ ! -d "$ROOT_HOME" ]; then
	printf '%s: %s does not exist\n' "$PROG" "$ROOT_HOME" >&2
	exit 1
fi
umask 022

# Whose settings to copy: the user who invoked pkexec or sudo, never a guess
# from who owns a directory, and never root -- if the read-as-user step ran
# as root, it would read anything. Cross-checked against the passwd database.
target_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
case "$target_uid" in
'')
	printf '%s: can'"'"'t tell whose GTK settings to copy: run --%s via pkexec or sudo from that user'"'"'s session (PKEXEC_UID and SUDO_UID are both unset)\n' \
		"$PROG" "$MODE" >&2
	exit 1
	;;
*[!0-9]*)
	printf '%s: invoking uid %s is not a number\n' "$PROG" "$target_uid" >&2
	exit 1
	;;
0)
	printf '%s: refusing to copy settings for uid 0: run --%s via pkexec or sudo from the desktop user'"'"'s session, not from root\n' \
		"$PROG" "$MODE" >&2
	exit 1
	;;
esac
if ! target_pw="$(getent passwd "$target_uid")"; then
	printf '%s: uid %s has no passwd entry\n' "$PROG" "$target_uid" >&2
	exit 1
fi
IFS=: read -r KARTIK_USER _ KARTIK_UID KARTIK_GID _ target_home _ <<<"$target_pw"
if [ "$KARTIK_UID" != "$target_uid" ] || [ "$KARTIK_UID" = 0 ] || [ -z "$KARTIK_USER" ]; then
	printf '%s: passwd entry for uid %s is unusable\n' "$PROG" "$target_uid" >&2
	exit 1
fi
# The home is the passwd entry's, not an inherited KARTIK_HOME (pkexec
# drops the environment anyway); only test mode keeps an override.
if [ "${SYNC_ROOT_GTK_TEST_HOME:-}" != 1 ]; then
	KARTIK_HOME="$target_home"
fi
if ! KARTIK_REAL="$(realpath -e -- "$KARTIK_HOME" 2>/dev/null)" || [ ! -d "$KARTIK_REAL" ]; then
	printf '%s: %s'"'"'s home %s is not an existing directory\n' "$PROG" "$KARTIK_USER" "$KARTIK_HOME" >&2
	exit 1
fi
if ! command -v setpriv >/dev/null 2>&1; then
	printf '%s: setpriv (util-linux) is needed to read %s'"'"'s files with %s'"'"'s privileges\n' \
		"$PROG" "$KARTIK_USER" "$KARTIK_USER" >&2
	exit 1
fi

# Run "$@" with kartik's privileges: uid, gid and supplementary groups from
# the passwd/group databases, via setpriv (no PAM or TTY needed, so it works
# under pkexec). Always a real drop -- KARTIK_UID is never 0 (checked above),
# so a read that goes through this can never reach a file kartik couldn't.
as_kartik() {
	setpriv --reuid="$KARTIK_UID" --regid="$KARTIK_GID" --init-groups -- "$@"
}

# Settings copied into root's files. Each one only changes how widgets look;
# none can name a module, file, or directory, and values must also match
# the safe character set in filter_settings.
APPEARANCE_KEYS="gtk-theme-name gtk-icon-theme-name gtk-cursor-theme-name
gtk-cursor-theme-size gtk-font-name gtk-application-prefer-dark-theme
gtk-xft-antialias gtk-xft-hinting gtk-xft-hintstyle gtk-xft-rgba gtk-xft-dpi
gtk-decoration-layout gtk-enable-animations gtk-button-images gtk-menu-images
gtk-toolbar-style"

MANAGED_HEADER="# Managed by sync-root-gtk-theme.sh"

# A temp file or directory to remove if the script dies before using it.
PENDING=""
trap 'if [ -n "$PENDING" ]; then rm -rf -- "$PENDING"; fi' EXIT

drift=0
failed=0

# Filter kartik's settings content (read on stdin) to the appearance-only
# allowlist and print root's copy. $1 is "ini" (gtk-3.0/gtk-4.0 settings.ini,
# a GKeyFile whose [Settings] group holds the keys) or "rc" (.gtkrc-2.0,
# where only top-level key = value lines count). $2 is kartik's path, for the
# header and messages only. $3 is 1 to list on stderr what was left out.
filter_settings() {
	local fmt="$1" src="$2" verbose="$3"
	printf '%s: appearance keys copied from\n# %s. Re-run --apply to refresh; edits here are overwritten.\n' \
		"$MANAGED_HEADER" "$src"
	if [ "$fmt" = ini ]; then
		printf '[Settings]\n'
	fi
	awk -v fmt="$fmt" -v keys="$APPEARANCE_KEYS" -v verbose="$verbose" -v prog="$PROG" -v src="$src" '
	function drop(what) {
		if (!(what in seen)) {
			seen[what] = 1
			dropped = dropped (dropped == "" ? "" : ", ") what
		}
	}
	BEGIN {
		n = split(keys, list, /[ \n]+/)
		for (i = 1; i <= n; i++) allow[list[i]] = 1
		depth = 0
		in_settings = (fmt == "rc")
	}
	{
		line = $0
		sub(/^[ \t]+/, "", line)
		sub(/[ \t\r]+$/, "", line)
		if (line == "" || line ~ /^#/) next
		if (fmt == "ini") {
			if (line ~ /^\[.*\]$/) { in_settings = (line == "[Settings]"); next }
			if (!in_settings) { drop("lines outside [Settings]"); next }
		} else {
			at_top = (depth == 0)
			bare = line
			gsub(/"[^"]*"/, "", bare)
			opens = gsub(/\{/, "", bare)
			closes = gsub(/\}/, "", bare)
			depth += opens - closes
			if (depth < 0) depth = 0
			if (!at_top || opens || closes) { drop("style/binding blocks"); next }
		}
		eq = index(line, "=")
		if (eq == 0) { drop("other statements (include, module_path, ...)"); next }
		key = substr(line, 1, eq - 1)
		sub(/[ \t]+$/, "", key)
		value = substr(line, eq + 1)
		sub(/^[ \t]+/, "", value)
		if (!(key in allow)) { drop(key); next }
		quoted = 0
		if (fmt == "rc" && value ~ /^".*"$/) {
			quoted = 1
			value = substr(value, 2, length(value) - 2)
		}
		if (value !~ /^[A-Za-z0-9 ._+,:@-]*$/ || value ~ /\.\./) { drop(key " (unsafe value)"); next }
		if (fmt == "rc" && !quoted && value !~ /^(-?[0-9]+|[A-Za-z_][A-Za-z0-9_]*)$/) { drop(key " (unquoted value)"); next }
		if (quoted) print key "=\"" value "\""
		else print key "=" value
	}
	END {
		if (verbose && dropped != "")
			printf "%s: from %s, left out: %s\n", prog, src, dropped > "/dev/stderr"
	}
	'
}

# Succeed if settings file $1 is one this script wrote (its first line is the
# managed header).
is_managed() {
	local first=""
	[ -f "$1" ] || return 1
	IFS= read -r first <"$1" || true
	case "$first" in
	"$MANAGED_HEADER"*) return 0 ;;
	esac
	return 1
}

# Create directory $1 (under ROOT_HOME) and any missing parents, refusing
# if any component is a symlink, so nothing is ever written through one.
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
		if [ ! -d "$path" ]; then
			mkdir -m 0755 -- "$path" || return 1
		fi
	done
}

# Move the finished settings file $1 to $2. A symlink there (left by an older
# version of this script) is removed first, never written through; a copy
# this script made is replaced; anything else is backed up.
put_in_place() {
	local new="$1" dest="$2" backup
	if [ -L "$dest" ]; then
		printf 'replacing symlink %s -> %s\n' "$dest" "$(readlink -- "$dest")"
		rm -f -- "$dest" || return 1
	elif [ -f "$dest" ] && [ -f "$new" ] && is_managed "$dest"; then
		: # mv -T below replaces it in one rename.
	elif [ -e "$dest" ]; then
		backup="${dest}.bak-$(date +%s)"
		mv -T -- "$dest" "$backup" || return 1
		printf 'backed up existing %s -> %s\n' "$dest" "$backup"
	fi
	# -T: never move into $dest, even if it's (or links to) a directory.
	mv -T -- "$new" "$dest"
}

# kartik's source $2 for root path $1 is gone or unusable (reason in $3):
# drop root's copy if this script made it, or any symlink, and leave the
# rest alone.
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

# 0 if settings source $1 is a regular file (following symlinks) that
# resolves inside KARTIK_HOME and is owned by KARTIK_UID, 1 if it doesn't
# exist, 2 if it's anything else: a dangling or non-regular target, one that
# resolves outside KARTIK_HOME, or one owned by another user. The content is
# still read as kartik, so this is defense in depth.
source_file_state() {
	local real owner
	if [ ! -e "$1" ] && [ ! -L "$1" ]; then
		return 1
	fi
	real="$(realpath -e -- "$1" 2>/dev/null)" || return 2
	[ -f "$real" ] || return 2
	case "$real" in
	"$KARTIK_REAL"/*) ;;
	*) return 2 ;;
	esac
	owner="$(stat -c %u -- "$real" 2>/dev/null)" || return 2
	[ "$owner" = "$KARTIK_UID" ] || return 2
	return 0
}

source_file_reason() {
	if [ "$1" -eq 2 ]; then
		printf 'unsafe source (symlink outside %s, not a regular file, or not owned by the user)' "$KARTIK_HOME"
	else
		printf 'does not exist'
	fi
}

# Print UNSAFE and succeed if $1, or a directory between ROOT_HOME and it,
# is a symlink.
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

# Print UNSAFE and succeed if anything at or under $1 isn't owned by root
# or is group/world-writable.
report_unsafe_perms() {
	local bad
	bad="$(find "$1" \( ! -user 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>&1)" ||
		bad="${bad:-$1 (find failed)}"
	if [ -n "$bad" ]; then
		printf 'UNSAFE  %s: %s is not root-owned or is group/world-writable\n' "$1" "$bad"
		drift=1
		return 0
	fi
	return 1
}

# True if $2 is installed as the right kind of appearance dir for $1:
# "themes" wants a GTK theme (a gtk-*.0 subdir), "icons" an icon or cursor
# theme (any directory of that name). Metadata only. Any further arguments
# are a command prefix to run the tests under (as_kartik for his own dirs).
is_appearance_dir() {
	local kind="$1" p="$2"
	shift 2
	if [ "$kind" = themes ]; then
		"$@" test -d "$p/gtk-2.0" || "$@" test -d "$p/gtk-3.0" || "$@" test -d "$p/gtk-4.0"
	else
		"$@" test -d "$p"
	fi
}

# NOTE (not a failure) when the appearance named $2 is only under kartik's
# user-local dirs. $1 is a label, $3 is "themes" or "icons". Root can't
# safely use a tree kartik can write -- not by reading it in place, and not
# by an automated copy, which would install whatever (links included) the
# tree holds at that moment -- so no root command is printed: kartik installs
# it system-wide by a route he trusts. Nothing is printed if it's already
# system-wide or not found. His dirs are probed as kartik.
note_if_user_local() {
	local label="$1" name="$2" kind="$3" d dest found=""
	[ -n "$name" ] || return 0
	# A plain theme name has no slash or control character; anything else
	# isn't a theme name to look up.
	case "$name" in *[[:cntrl:]/]*) return 0 ;; esac
	local -a sysdirs userdirs
	if [ "$kind" = themes ]; then
		sysdirs=(/usr/share/themes /usr/local/share/themes)
		userdirs=("$KARTIK_HOME/.themes" "$KARTIK_HOME/.local/share/themes")
		dest=/usr/local/share/themes
	else
		sysdirs=(/usr/share/icons /usr/local/share/icons)
		userdirs=("$KARTIK_HOME/.icons" "$KARTIK_HOME/.local/share/icons")
		dest=/usr/local/share/icons
	fi
	for d in "${sysdirs[@]}"; do
		is_appearance_dir "$kind" "$d/$name" && return 0
	done
	for d in "${userdirs[@]}"; do
		if is_appearance_dir "$kind" "$d/$name" as_kartik; then
			found="$d/$name"
			break
		fi
	done
	[ -n "$found" ] || return 0
	printf '%s: NOTE: the %s %q is user-local (%q), so root GTK apps fall back to the default. Root can'"'"'t safely use a tree your account can write, so this script copies nothing from it and prints no install command. Install it system-wide by a route you trust: the distro or AUR package if one exists, or a manual copy into %s that you have reviewed.\n' \
		"$PROG" "$label" "$name" "$found" "$dest" >&2
}

# Note (in both --apply and --check) each configured theme, icon theme and
# cursor theme that is only under kartik's user-local dirs. The names are read
# as kartik, from his gtk-3.0 settings.ini, and only if it passes the source
# checks. These are NOTEs, not drift.
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
	# Read as kartik, so even a source that slipped past the checks can't
	# hand root a file kartik can't read.
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
	if [ "$state" -ne 0 ]; then
		if [ -e "$dest" ] && is_managed "$dest"; then
			printf 'STALE   %s (%s %s; --apply removes it)\n' "$dest" "$src" "$(source_file_reason "$state")"
			drift=1
		else
			printf 'skip    %s (%s %s)\n' "$dest" "$src" "$(source_file_reason "$state")"
		fi
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

# Run "<$1>_file" over every settings target, carrying on past a failed one.
# Each line is the format, then root's path, then kartik's path.
TARGET_FILES=(
	rc "$ROOT_HOME/.gtkrc-2.0" "$KARTIK_HOME/.gtkrc-2.0"
	ini "$ROOT_HOME/.config/gtk-3.0/settings.ini" "$KARTIK_HOME/.config/gtk-3.0/settings.ini"
	ini "$ROOT_HOME/.config/gtk-4.0/settings.ini" "$KARTIK_HOME/.config/gtk-4.0/settings.ini"
)
# Paths under /root that can leave root GTK reading kartik's user-writable
# appearance trees, each with its kind. The symlink era linked the two theme
# paths into his home; the current script creates and copies none of them.
# A theme path is handled whatever is there (root has no theme dir of its own
# to keep). An icon path is often root's own (e.g. /root/.icons/default
# setting root's cursor), so it is handled only when it is a symlink into
# kartik's home or a dir carrying LEGACY_MARKER, which the copy era (never
# run as root on a real host) put in each icon dir it wrote; anything else
# there is root's and is left alone, unreported. --check flags them; --apply
# removes a symlink or renames a dir aside, never deleting recursively (see
# classify_legacy).
LEGACY_DIRS=(
	theme "$ROOT_HOME/.themes"
	theme "$ROOT_HOME/.local/share/themes"
	icon "$ROOT_HOME/.icons"
	icon "$ROOT_HOME/.local/share/icons"
)
LEGACY_MARKER=".sync-root-gtk-theme"

# True if $1 is inside kartik's home (as given or as resolved).
in_kartik_home() {
	case "$1" in
	"$KARTIK_HOME" | "$KARTIK_HOME"/* | "$KARTIK_REAL" | "$KARTIK_REAL"/*) return 0 ;;
	esac
	return 1
}

# True if the symlink $1 points into kartik's home: by its own target
# (lexically, so a link into his tree counts even if he points that onward
# somewhere innocent today) or by where the whole chain finally resolves.
# Metadata only; nothing is opened.
links_into_home() {
	local raw lex full
	raw="$(readlink -- "$1")" || return 1
	case "$raw" in
	/*) ;;
	*) raw="$(dirname -- "$1")/$raw" ;;
	esac
	lex="$(realpath -m -s -- "$raw" 2>/dev/null)" || lex=""
	full="$(realpath -m -- "$1" 2>/dev/null)" || full=""
	{ [ -n "$lex" ] && in_kartik_home "$lex"; } || { [ -n "$full" ] && in_kartik_home "$full"; }
}

# Echo the highest directory strictly between ROOT_HOME and $1 that is a
# symlink, or nothing if every ancestor is a real directory. Walks parents
# with dirname (no path splitting), so a newline in a component can't
# truncate it; the legacy paths are fixed strings anyway.
symlinked_ancestor() {
	local path highest=""
	path="$(dirname -- "$1")"
	while [ "$path" != "$ROOT_HOME" ] && [ "$path" != / ] && [ "$path" != . ]; do
		[ -L "$path" ] && highest="$path"
		path="$(dirname -- "$path")"
	done
	printf '%s' "$highest"
}

# The single classification --check and --apply share, so they can't
# disagree. $1 is the kind (theme or icon), $2 the path. It NEVER recurses
# into or deletes a directory. Echoes:
#   none     - nothing to do: nothing is there, or (icon paths) it is root's
#              own, not a link into kartik's home or a marked copy
#   symlink  - $2 itself is a symlink (for an icon path, one into kartik's
#              home); remove the link only (rm -f never touches the target)
#   ancestor - a directory above $2 (under ROOT_HOME) is a symlink; don't
#              touch anything below it (that could reach into kartik's
#              home); report it and leave its removal to kartik
#   backup   - a real path with only real ancestors (for an icon path, a
#              dir holding LEGACY_MARKER); rename it aside with mv -T (a
#              rename can't recurse) -- whatever it holds
classify_legacy() {
	local kind="$1" path="$2"
	if [ -n "$(symlinked_ancestor "$path")" ]; then
		echo ancestor
		return 0
	fi
	if [ -L "$path" ]; then
		if [ "$kind" = icon ] && ! links_into_home "$path"; then
			echo none
			return 0
		fi
		echo symlink
		return 0
	fi
	if [ ! -e "$path" ]; then
		echo none
		return 0
	fi
	if [ "$kind" = icon ] && { [ ! -d "$path" ] || [ ! -f "$path/$LEGACY_MARKER" ]; }; then
		echo none
		return 0
	fi
	echo backup
}

# --check: report exactly what --apply would do to a legacy path ($1 kind, $2 path).
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
	return 0
}

# --apply: act on a legacy path, per the shared classification. Never
# deletes a directory: a symlink at the path is unlinked; a path under a
# symlinked ancestor is refused (that ancestor could reach into kartik's
# home, so removing it is left to kartik); a real path is renamed aside.
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

run_legacy() {
	local i
	for ((i = 0; i < ${#LEGACY_DIRS[@]}; i += 2)); do
		"$1" "${LEGACY_DIRS[@]:i:2}" || target_failed
	done
}
target_failed() {
	failed=1
	if [ -n "$PENDING" ]; then
		rm -rf -- "$PENDING"
		PENDING=""
	fi
}
run_all() {
	local i
	for ((i = 0; i < ${#TARGET_FILES[@]}; i += 3)); do
		"${1}_file" "${TARGET_FILES[@]:i:3}" || target_failed
	done
}

if [ "$MODE" = check ]; then
	warn_user_local
	run_all check
	run_legacy check_legacy
	if [ "$failed" -ne 0 ]; then
		exit 1
	fi
	exit "$drift"
fi

warn_user_local
run_all apply
run_legacy apply_legacy
echo "--- verify ---"
drift=0
run_all check
run_legacy check_legacy
if [ "$failed" -ne 0 ] || [ "$drift" -ne 0 ]; then
	exit 1
fi
