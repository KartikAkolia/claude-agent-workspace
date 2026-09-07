#!/usr/bin/env bash
# sync-root-gtk-theme.sh — keep root's GTK config symlinked to kartik's, so
# GParted (and any other pkexec/su-elevated GTK app) always renders whatever
# theme kartik is currently running, without re-copying config by hand. Also
# discovers installed GTK themes the way lxappearance/nwg-look do (scanning
# the standard theme directories for a gtk-2.0/gtk-3.0/gtk-4.0 subdirectory)
# and can set one as kartik's active theme directly, whiptail picker
# included.
#
# Root cause and history: docs/gparted-root-theme-fix.md. Short version:
# pkexec runs GTK apps as root with $HOME=/root, so root reads its own GTK
# config, not kartik's -- and a one-off static copy of that config drifts out
# of sync the next time kartik switches themes. Symlinking instead of copying
# fixes that permanently: root's config *is* kartik's config from then on. A
# theme that lives only under kartik's ~/.local/share/themes (as user-local
# themes like Catppuccin do, rather than system-wide under /usr/share/themes)
# needs the same treatment, since root's $HOME never reaches into
# /home/kartik on its own -- so that directory is symlinked too.
#
# Because of that symlink, --set/--pick below never need sudo: they only
# ever rewrite kartik's own files, and root reads the same paths already.
# --check/--apply (the original, still-default behavior) are the only modes
# that touch anything under /root, and are the only ones that need it.
#
# Idempotent -- safe to re-run any time (e.g. after a theme switch, or just
# to confirm nothing has drifted). Existing real files/directories at the
# target paths are backed up, not deleted, before being replaced.
#
# Everything under /root is mode 0700, so --check/--apply have to go through
# sudo for every read or write against it, including plain existence checks
# -- there is no way for kartik to even stat a path under /root otherwise.
# Run this as kartik; it escalates itself per-command.

set -euo pipefail

PROG="$(basename "$0")"
KARTIK_HOME="${KARTIK_HOME:-/home/kartik}"
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
Usage: $PROG [--check | --list | --set THEME | --pick | -h|--help]

  (no flags)   Ensure root's GTK config/theme dir are symlinked to
               \$KARTIK_HOME ($KARTIK_HOME). Needs sudo.
  --check      Report whether those symlinks are correctly in place,
               without changing anything. Needs sudo. Exits 1 on any drift.
  --list       List installed GTK themes found under:
$(printf '                 %s\n' "${THEME_DIRS[@]}")
               No sudo needed.
  --set THEME  Set THEME as kartik's active GTK theme (gtk-3.0, gtk-4.0,
               and .gtkrc-2.0). No sudo needed -- root already reads these
               same files through the symlinks --apply sets up.
  --pick       Same as --set, but choose the theme from a whiptail menu.
  -h --help    Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
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

if [ ! -d "$KARTIK_HOME" ]; then
	printf '%s: %s does not exist\n' "$PROG" "$KARTIK_HOME" >&2
	exit 1
fi

# --- theme discovery / setting (no sudo needed for any of this) -----------

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

# Upsert key=value (or key="value" if quoted=1) in an INI-style file,
# preserving every other line. Writes via a same-directory temp file plus
# mv so a mid-write failure can't leave the config half-written.
set_kv() {
	local file="$1" key="$2" value="$3" quoted="$4" tmp

	if [ ! -f "$file" ]; then
		printf '%s: %s not found, skipping\n' "$PROG" "$file" >&2
		return 1
	fi

	tmp="$(mktemp "${file}.XXXXXX")" || return 1
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
		mv "$tmp" "$file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Validate $1 against the discovered theme list, then write it into all
# three files root's symlinks already point at.
apply_theme() {
	local name="$1" t found=0
	local available=()

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

	set_kv "$KARTIK_HOME/.config/gtk-3.0/settings.ini" gtk-theme-name "$name" 0
	set_kv "$KARTIK_HOME/.config/gtk-4.0/settings.ini" gtk-theme-name "$name" 0
	set_kv "$KARTIK_HOME/.gtkrc-2.0" gtk-theme-name "$name" 1

	printf 'gtk-theme-name set to %s.\n' "$name"
	printf 'Root reads these same files through its existing symlinks (docs/gparted-root-theme-fix.md) -- no sudo needed for this to take effect. Run "%s --check" any time to confirm the symlinks are still in place.\n' "$PROG"
}

wt() {
	whiptail --backtitle "$PROG" "$@"
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
	apply_theme "$THEME_NAME"
	exit 0
	;;
pick)
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

# --- everything below here is --check / (default) --apply, unchanged ------
# behavior from before --list/--set/--pick existed, and the only modes that
# touch /root.

if ! command -v sudo >/dev/null 2>&1; then
	printf '%s: sudo not found on PATH\n' "$PROG" >&2
	exit 1
fi

# Validate/refresh the sudo ticket once, up front, with its own error message
# visible. Everything under /root needs sudo to even stat, and each check
# below swallows its sudo call's stderr to tell "not a symlink" apart from
# real command output -- without this guard, a plain auth failure (wrong
# password, no TTY, not in sudoers) would be swallowed the same way and
# misreported as every path being out of sync.
if ! sudo -v; then
	printf '%s: could not obtain sudo privileges\n' "$PROG" >&2
	exit 1
fi

# root path -> the kartik-owned path it should be a symlink to.
LINKS=(
	"/root/.gtkrc-2.0:$KARTIK_HOME/.gtkrc-2.0"
	"/root/.config/gtk-3.0/settings.ini:$KARTIK_HOME/.config/gtk-3.0/settings.ini"
	"/root/.config/gtk-4.0/settings.ini:$KARTIK_HOME/.config/gtk-4.0/settings.ini"
	"/root/.local/share/themes:$KARTIK_HOME/.local/share/themes"
)

drift=0

for pair in "${LINKS[@]}"; do
	root_path="${pair%%:*}"
	real_path="${pair#*:}"

	# readlink prints nothing and exits nonzero for a missing path or one
	# that isn't a symlink -- `|| true` keeps that from tripping set -e, and
	# an empty $current then just compares unequal to $real_path below.
	current="$(sudo readlink "$root_path" 2>/dev/null || true)"

	if [ "$MODE" = "check" ]; then
		if [ "$current" = "$real_path" ]; then
			printf 'ok      %s -> %s\n' "$root_path" "$real_path"
		else
			printf 'DRIFT   %s (expected symlink to %s)\n' "$root_path" "$real_path"
			drift=1
		fi
		continue
	fi

	if [ ! -e "$real_path" ] && [ ! -L "$real_path" ]; then
		printf '%s: %s does not exist, skipping %s\n' "$PROG" "$real_path" "$root_path" >&2
		continue
	fi

	if [ "$current" = "$real_path" ]; then
		printf 'already linked: %s\n' "$root_path"
		continue
	fi

	# Something else is at $root_path -- a stale symlink, a leftover static
	# copy from an earlier fix, or a real directory -- back it up rather
	# than clobber it.
	if sudo test -e "$root_path" || sudo test -L "$root_path"; then
		backup="${root_path}.bak-$(date +%s)"
		sudo mv "$root_path" "$backup"
		printf 'backed up existing %s -> %s\n' "$root_path" "$backup"
	fi

	sudo mkdir -p "$(dirname "$root_path")"
	sudo ln -s "$real_path" "$root_path"
	printf 'linked %s -> %s\n' "$root_path" "$real_path"
done

if [ "$MODE" = "check" ]; then
	exit "$drift"
fi

echo "--- verify ---"
for pair in "${LINKS[@]}"; do
	root_path="${pair%%:*}"
	sudo ls -la "$root_path"
done
