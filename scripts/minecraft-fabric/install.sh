#!/usr/bin/env bash
# install.sh — install (or update) a standalone Fabric Minecraft server on a
# fresh Linux host, optionally with Geyser (Bedrock clients) and Floodgate
# (Bedrock players without a Java account).
#
# Interactive by default. It asks for the Minecraft version, the server type
# (Java only / + Geyser / + Geyser and Floodgate), how to run it (systemd user
# unit, systemd system unit under a dedicated "minecraft" user, or a start.sh
# launcher only) and the install directory. Everything else is resolved for
# that version:
#   Fabric loader and installer  latest stable, from meta.fabricmc.net
#   Java                         Mojang's required major version (offered for
#                                install via pacman/apt/dnf/zypper if missing)
#   Fabric API, Geyser-Fabric,   newest Modrinth build for the version,
#   Floodgate-Fabric             checked against Modrinth's SHA-512
# All lookups happen before anything in the server directory or systemd is
# written, so an unsupported pairing (e.g. Floodgate has no Fabric build for
# that version) stops cleanly. Missing tools and Java are the exception: they
# are offered for install (a prompt; --yes accepts) before the summary.
#
# Safe to rerun: it updates the launcher and managed mods, removes managed
# mods no longer selected, and keeps server.properties, the world and any
# other mods. Other jars in mods/ are left alone.
#
#   install.sh [options]
#     --mc-version VER   Minecraft version, e.g. 26.3 (default: latest stable)
#     --type TYPE        java | geyser | floodgate (geyser + floodgate)
#     --service MODE     user | system | none
#     --dir DIR          server directory
#     --heap SIZE        max Java heap, e.g. 4G or 3072M; "auto" is half of
#                        RAM between 1G and 4G (default: the last run's
#                        value, else auto)
#     --accept-eula      agree to https://aka.ms/MinecraftEULA (eula=true)
#     --yes              take the default for every unanswered question
#                        (never accepts the EULA or opens the firewall)
#
# Java listens on TCP 25565; Geyser on UDP 19132 for gameplay and TCP 19132
# for NetherNet signaling.

set -euo pipefail

readonly FABRIC_META=https://meta.fabricmc.net/v2
readonly MODRINTH=https://api.modrinth.com/v2
readonly MOJANG_MANIFEST=https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
# Modrinth asks API clients for a User-Agent that identifies them.
readonly USER_AGENT="KartikAkolia/claude-agent-workspace minecraft-fabric-install"
readonly UNIT_NAME=minecraft-fabric.service
readonly SYSTEM_USER=minecraft
readonly STATE_FILE=.install-state
readonly JAVA_PORT=25565
readonly BEDROCK_PORT=19132

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
	sed -n '/^#   install.sh/,/^# for NetherNet/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mc_version='' server_type='' service_mode='' server_dir='' heap='' choice=''
accept_eula=false assume_yes=false
while (($#)); do
	case $1 in
	--mc-version | --type | --service | --dir | --heap)
		[[ -n ${2:-} && $2 != --* ]] || die "$1 needs a value"
		case $1 in
		--mc-version) mc_version=$2 ;;
		--type) server_type=$2 ;;
		--service) service_mode=$2 ;;
		--dir) server_dir=$2 ;;
		--heap) heap=$2 ;;
		esac
		shift
		;;
	--accept-eula) accept_eula=true ;;
	--yes) assume_yes=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done
[[ -z $heap || $heap == auto || $heap =~ ^[1-9][0-9]*[GgMm]$ ]] || die "--heap needs a size like 4G or 3072M, or auto"
[[ -z $server_type || $server_type =~ ^(java|geyser|floodgate)$ ]] || die "--type must be java, geyser or floodgate"
[[ -z $service_mode || $service_mode =~ ^(user|system|none)$ ]] || die "--service must be user, system or none"
((EUID != 0)) || die "run as a normal user; the script uses sudo only where it has to"
me=$(id -un)

# --- prompting ---------------------------------------------------------------

# ask VAR QUESTION DEFAULT — reads from the terminal, so it works even when
# stdin is redirected. With --yes the default is taken without asking.
# shellcheck disable=SC2034 # ask_out is a nameref to the caller's variable
ask() {
	local -n ask_out=$1
	local ask_reply
	if $assume_yes; then
		ask_out=$3
		return
	fi
	{ : </dev/tty; } 2>/dev/null || die "no terminal to ask on; pass the options and --yes"
	read -r -p "$2 [$3]: " ask_reply </dev/tty
	ask_out=${ask_reply:-$3}
}

# confirm QUESTION y|n — succeeds on yes.
confirm() {
	local answer
	ask answer "$1 (y/n)" "$2"
	[[ ${answer,,} == y* ]]
}

# --- helpers for the server directory ---------------------------------------
# In system mode the directory belongs to $SYSTEM_USER, so every read and
# write inside it goes through these instead of plain commands.

as_owner() {
	if [[ $service_mode == system ]]; then
		# From /: $SYSTEM_USER may not be allowed into our working directory,
		# which makes tools like find fail. Every path passed is absolute.
		(cd / && sudo -u "$SYSTEM_USER" "$@")
	else
		"$@"
	fi
}

# place SRC DEST MODE — copy beside the destination, then rename atomically.
place() (
	# This subshell owns its cleanup variable even after callers unwind on error.
	place_staged=$(as_owner mktemp "$(dirname "$2")/.install-file.XXXXXX") || return
	trap 'as_owner rm -f -- "$place_staged" || true' EXIT
	if [[ $service_mode == system ]]; then
		sudo install -o "$SYSTEM_USER" -g "$system_group" -m "$3" "$1" "$place_staged" || return
	else
		install -m "$3" "$1" "$place_staged" || return
	fi
	as_owner mv -fT -- "$place_staged" "$2"
)

# Keep artifact backups private to the installer, including in system mode.
artifact_cmd() {
	if [[ $service_mode == system ]]; then sudo "$@"; else "$@"; fi
}
remember_artifact() {
	local dest=$1 backup=''
	[[ ! ${saved_artifacts[$dest]+saved} ]] || return 0
	if as_owner test -e "$dest" || as_owner test -L "$dest"; then
		backup=$tmp/artifact.${#artifact_paths[@]}
		artifact_cmd cp -a -- "$dest" "$backup" || return
	fi
	printf '%s\t%s\n' "$dest" "$backup" >>"$tmp/recovery-map"
	saved_artifacts[$dest]=1
	artifact_paths+=("$dest") artifact_backups+=("$backup")
}
rollback_artifacts() {
	local i failed=false
	for ((i = ${#artifact_paths[@]} - 1; i >= 0; i--)); do
		if [[ -n ${artifact_backups[i]} ]]; then
			artifact_cmd mv -fT -- "${artifact_backups[i]}" "${artifact_paths[i]}" || failed=true
		else
			as_owner rm -f -- "${artifact_paths[i]}" || failed=true
		fi
	done
	! $failed
}

# write_file DEST MODE <content — stage stdin, then place it.
write_file() {
	local staged
	staged=$(mktemp -p "$tmp")
	cat >"$staged"
	place "$staged" "$1" "$2"
}

# --- system packages ---------------------------------------------------------

detect_pm() {
	local pm
	for pm in pacman apt-get dnf zypper; do
		command -v "$pm" >/dev/null && {
			echo "$pm"
			return
		}
	done
	return 1
}

pkg_available() {
	case $pm in
	pacman) pacman -Si "$1" ;;
	apt-get) apt-cache show "$1" ;;
	dnf) dnf -q info "$1" ;;
	zypper) zypper -nq search -x "$1" ;;
	esac >/dev/null 2>&1
}

pkg_install() {
	case $pm in
	pacman) sudo pacman -S --needed --noconfirm "$@" ;;
	apt-get) sudo apt-get install -y "$@" ;;
	dnf) sudo dnf install -y "$@" ;;
	zypper) sudo zypper -n install "$@" ;;
	esac
}

pm=$(detect_pm) || pm=
apt_updated=false
apt_update_once() {
	if [[ $pm == apt-get ]] && ! $apt_updated; then
		sudo apt-get update
		apt_updated=true
	fi
}

missing=()
for cmd in curl python3 sha512sum sudo; do
	command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if ((${#missing[@]})); then
	[[ -n $pm && ! " ${missing[*]} " =~ \ sudo\  ]] || die "missing: ${missing[*]}; install them and rerun"
	confirm "Missing ${missing[*]}. Install with $pm?" y || die "missing: ${missing[*]}"
	pkgs=()
	for cmd in "${missing[@]}"; do
		case $cmd:$pm in
		python3:pacman) pkgs+=(python) ;;
		python3:*) pkgs+=(python3) ;;
		sha512sum:*) pkgs+=(coreutils) ;;
		*) pkgs+=("$cmd") ;;
		esac
	done
	apt_update_once
	pkg_install "${pkgs[@]}"
fi

tmp=$(mktemp -d)
boot_pid='' boot_stop_failed=false
artifacts_pending=false artifact_paths=() artifact_backups=()
declare -A saved_artifacts
# Whatever way the script ends, a first-boot server must not outlive it.
finished=false stopped_units=()
# on_exit — stop a first-boot server, and if the script dies after stopping
# a running server, say so: nothing restarts it automatically.
on_exit() {
	local status=$? keep_tmp=false
	if [[ -n $boot_pid ]]; then
		if $boot_stop_failed || ! shut_down_boot; then
			warn "first-boot shutdown is unfinished; do not start another server. PID file: $boot_pidfile; logs: $tmp"
			status=1 keep_tmp=true
		fi
	fi
	if $artifacts_pending; then
		if rollback_artifacts; then
			warn "restored the previous launcher, managed mods and install state after the failed update"
		else
			warn "artifact recovery failed; do not start the server. Backups and destination map are in $tmp"
			status=1 keep_tmp=true
		fi
	fi
	$keep_tmp || rm -rf "$tmp"
	if ! $finished && ((${#stopped_units[@]})); then
		local scope hints=()
		for scope in "${stopped_units[@]}"; do
			if [[ $scope == user ]]; then hints+=("systemctl --user start $UNIT_NAME"); else hints+=("sudo systemctl start $UNIT_NAME"); fi
		done
		if $keep_tmp; then
			warn "the service was stopped; finish recovery before starting it again"
		else
			warn "the server was stopped for this update and is still down; rerun the installer before starting it with: ${hints[0]}${hints[1]:+, then ${hints[1]}}"
		fi
	fi
	exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fetch() { curl -fsSL --proto =https --proto-redir =https -A "$USER_AGENT" "$@"; }

# json EXPR [ARG...] <json — print a Python expression over the parsed input
# "d"; extra arguments arrive as sys.argv[1:].
json() {
	local expr=$1
	shift
	python3 -Ic "import json, sys; d = json.load(sys.stdin); print($expr)" "$@"
}

# --- questions ---------------------------------------------------------------

# Fetched into variables first: pipefail doesn't reach inside a here-string's
# producer, so a failed lookup would otherwise go unnoticed.
game_versions=$(fetch "$FABRIC_META/versions/game") || die "can't reach meta.fabricmc.net"
latest=$(json 'next((g["version"] for g in d if g["stable"]), "")' <<<"$game_versions") || latest=''
[[ -n $latest ]] || die "unexpected answer from meta.fabricmc.net (no stable Minecraft versions)"

while :; do
	[[ -n $mc_version ]] || ask mc_version "Minecraft version" "$latest"
	if json "any(g['version'] == sys.argv[1] for g in d)" "$mc_version" <<<"$game_versions" | grep -qx True; then
		break
	fi
	recent=$(json '", ".join(g["version"] for g in d if g["stable"])' <<<"$game_versions" | cut -d, -f1-8)
	$assume_yes && die "Fabric doesn't support Minecraft '$mc_version'"
	warn "Fabric doesn't support Minecraft '$mc_version'. Recent releases: $recent, ..."
	mc_version=
done

dir_defaulted=false
if [[ -z $server_dir ]]; then
	# On a rerun, point at whichever default location already holds a server.
	if [[ $service_mode == system ]] || [[ -z $service_mode && ! -e $HOME/minecraft-fabric && -e /srv/minecraft-fabric ]]; then
		default=/srv/minecraft-fabric
	else
		default=$HOME/minecraft-fabric
	fi
	ask server_dir "Server directory (an existing install there is updated)" "$default"
	[[ $server_dir != "$default" ]] || dir_defaulted=true
fi
case $server_dir in
\~ | \~/*) server_dir=$HOME${server_dir#\~} ;;
\~*) die "give the directory as an absolute path, not $server_dir" ;;
esac
server_dir=$(realpath -m -- "$server_dir")
# The path ends up in start.sh, a unit file and sudo command lines; keeping
# it to plain characters avoids a quoting bug in any of them.
[[ $server_dir =~ ^[A-Za-z0-9\ _@+=:,./-]+$ ]] ||
	die "use a directory path of letters, digits, spaces and _@+=:,./- only: $server_dir"

# in_home PATH — whether PATH resolves into a home directory, which a
# system unit's $SYSTEM_USER can't reach (symlinked /home included).
in_home() {
	case $(realpath -m -- "$1")/ in
	"$(realpath -m /home)"/* | "$(realpath -m /root)"/* | "$(realpath -m "$HOME")"/*) return 0 ;;
	esac
	return 1
}

# peek CMD... — read from an existing install. A system-mode one belongs to
# $SYSTEM_USER with mode 750, so fall back to sudo only when the directory
# exists but is closed to us (not when it or the file is simply missing).
peek() {
	"$@" 2>/dev/null && return
	[[ -d $server_dir && ! (-r $server_dir && -x $server_dir) ]] || return 1
	sudo "$@" 2>/dev/null
}

read_geyser_ports() {
	local config port
	# Read the scalar settings in Geyser's generated block-style YAML without
	# requiring a YAML package. Reject unsupported values rather than open a
	# guessed port. Indentation, quoted scalars and comments are accepted.
	config=$(peek cat "$server_dir/config/Geyser-Fabric/config.yml" || true)
	port=$(python3 -Ic '
import re, sys
settings = {}
stack = []
for line in sys.stdin:
    match = re.fullmatch(r"( *)([\w-]+):(?:\s+(.*))?\s*", line.rstrip())
    if not match:
        continue
    indent, key, value = match.groups()
    while stack and stack[-1][0] >= len(indent):
        stack.pop()
    path = ".".join([entry[1] for entry in stack] + [key])
    value = (value or "").split("#", 1)[0].strip()
    if value and path in ("bedrock", "bedrock.signaling"):
        sys.exit("Use block-style mappings for Geyser " + path)
    if not value:
        stack.append((len(indent), key))
    else:
        settings[path] = value.strip("\"\x27").lower()
def port(key, default):
    value = settings.get(key, str(default))
    if not value.isdecimal() or not 0 <= int(value) <= 65535:
        sys.exit("Invalid Geyser port: " + key)
    return int(value)
base = port("bedrock.port", sys.argv[2])
if not base:
    sys.exit("Geyser bedrock.port must be a fixed nonzero port")
clone = settings.get("bedrock.clone-remote-port", "false")
if clone not in ("true", "false"):
    sys.exit("Invalid Geyser clone-remote-port; use true or false")
if clone == "true":
    base = int(sys.argv[1])
udp = port("bedrock.webrtc-port", 0) or base
tcp = port("bedrock.signaling.port", 0) or base
mode = settings.get("bedrock.signaling.mode", "builtin")
if mode not in ("builtin", "hybrid", "nxs"):
    sys.exit("Invalid Geyser signaling mode: " + mode)
# Built-in signaling falls back to NXS when Java already owns its TCP port.
if mode == "nxs" or tcp == int(sys.argv[1]):
    tcp = 0
print(udp, tcp)' "$java_port" "$BEDROCK_PORT" <<<"$config") || die "couldn't resolve Geyser ports in $server_dir/config/Geyser-Fabric/config.yml"
	read -r bedrock_port signaling_port <<<"$port"
}

# read_existing — what an earlier run recorded: a rerun keeps its type and
# mode by default, and the version is checked before the world moves on.
read_existing() {
	local state port
	previous_version='' previous_type='' previous_mode='' previous_launcher='' java_port=$JAVA_PORT
	previous_jars=() previous_heap='' bedrock_port=$BEDROCK_PORT signaling_port=$BEDROCK_PORT
	[[ -d $server_dir ]] || return 0
	[[ -r $server_dir && -x $server_dir ]] || info "Reading the existing install in $server_dir with sudo"
	state=$(peek cat "$server_dir/$STATE_FILE" || true)
	previous_version=$(sed -n 's/^mc_version=//p' <<<"$state")
	previous_type=$(sed -n 's/^server_type=//p' <<<"$state")
	previous_mode=$(sed -n 's/^service_mode=//p' <<<"$state")
	previous_launcher=$(sed -n 's/^\(loader\|installer\)_version=//p' <<<"$state" | paste -sd/)
	previous_heap=$(sed -n 's/^heap=\([1-9][0-9]*[GgMm]\)$/\1/p' <<<"$state")
	# The jars an earlier run installed, by exact name.
	mapfile -t previous_jars < <(sed -n 's/^mod_[a-z-]*=\([A-Za-z0-9][A-Za-z0-9._+-]*\.jar\)$/\1/p' <<<"$state")
	# Installs made before the state file existed: the vanilla jar's folder
	# (the most recently written one, if the server was upgraded before).
	if [[ -z $previous_version ]]; then
		previous_version=$(peek find "$server_dir/versions" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
			sort -nr | head -n1 | cut -d' ' -f2- || true)
	fi
	port=$(peek cat "$server_dir/server.properties" | sed -n 's/^server-port=//p' || true)
	[[ ! $port =~ ^[0-9]+$ ]] || java_port=$port

}
read_existing

have_systemd=false
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] && have_systemd=true
if [[ -z $service_mode ]]; then
	printf '%s\n' "How should the server run?" \
		"  1) systemd user unit    (runs as you, no sudo; needs lingering to run while logged out)" \
		"  2) systemd system unit  (dedicated '$SYSTEM_USER' user, starts at boot; needs sudo)" \
		"  3) start.sh only        (foreground console, no service)"
	case $previous_mode in
	user) default=1 ;;
	system) default=2 ;;
	none) default=3 ;;
	*) if $have_systemd; then default=1; else default=3; fi ;;
	esac
	ask choice "Choose 1-3" "$default"
	case $choice in
	1) service_mode=user ;;
	2) service_mode=system ;;
	3) service_mode=none ;;
	*) die "no such choice: $choice" ;;
	esac
fi
case $service_mode in
user | system) $have_systemd || die "systemd isn't running here; use --service none" ;;
none) ;;
*) die "--service must be user, system or none" ;;
esac
if [[ $service_mode == user ]] && ! systemctl --user show-environment >/dev/null 2>&1; then
	die "no systemd user session (common over su or some SSH setups); log in directly or use --service system"
fi

# A system unit runs as $SYSTEM_USER, which can't reach into home directories.
if [[ $service_mode == system ]]; then
	case $server_dir/ in
	/tmp/* | /var/tmp/*) die "a system-mode server can't live in $server_dir: the unit gives the server a private /tmp" ;;
	esac
	if in_home "$server_dir"; then
		# The directory prompt came before the mode one; move a default along.
		if ! $dir_defaulted || [[ -e $server_dir ]]; then
			die "a system-mode server can't live in a home directory ($server_dir); move it to e.g. /srv/minecraft-fabric first, or pick user mode"
		fi
		server_dir=/srv/minecraft-fabric
		info "System mode: using $server_dir instead"
		read_existing
	fi
fi
# Switching modes on an existing directory means switching its owner too.
dir_owner=''
[[ ! -e $server_dir ]] || dir_owner=$(stat -c %U "$server_dir")
if [[ -n $dir_owner && $service_mode == system && $dir_owner != "$SYSTEM_USER" ]]; then
	# chown -R is only safe on a server directory: never on /srv, /opt or /
	# because they were typed by mistake.
	[[ $(dirname "$server_dir") != / ]] ||
		die "refusing to hand the top-level directory $server_dir over to $SYSTEM_USER; use one inside it, e.g. $server_dir/minecraft-fabric"
	if [[ -n $(sudo find "$server_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] &&
		! sudo test -f "$server_dir/server.properties" -o -f "$server_dir/$STATE_FILE"; then
		die "$server_dir isn't empty and doesn't look like a Minecraft server; refusing to hand it over to $SYSTEM_USER. Use a new directory such as $server_dir/minecraft-fabric"
	fi
	warn "$server_dir belongs to $dir_owner; a system-mode server needs it and everything in it owned by $SYSTEM_USER."
	confirm "Hand $server_dir over to $SYSTEM_USER?" y || die "cancelled"
elif [[ -n $dir_owner && $service_mode != system && $dir_owner != "$me" ]]; then
	die "$server_dir belongs to $dir_owner${previous_mode:+ (a $previous_mode-mode install)}; rerun with --service system, or take it over first: sudo chown -R $me: $(printf %q "$server_dir")"
elif [[ -z $dir_owner && $service_mode != system ]]; then
	# Find out now, not after stopping a running server, if it can't be made.
	parent=$server_dir
	while [[ ! -e $parent ]]; do parent=$(dirname "$parent"); done
	[[ -w $parent && -x $parent ]] ||
		die "can't create $server_dir ($parent isn't writable by $me); pick another directory or use --service system"
fi

if [[ -z $server_type ]]; then
	printf '%s\n' "Server type:" \
		"  1) Java only" \
		"  2) Java + Geyser            (Bedrock players sign in with a Java account)" \
		"  3) Java + Geyser + Floodgate (Bedrock players need no Java account)"
	case $previous_type in
	java) default=1 ;;
	geyser) default=2 ;;
	*) default=3 ;;
	esac
	ask choice "Choose 1-3" "$default"
	case $choice in
	1) server_type=java ;;
	2) server_type=geyser ;;
	3) server_type=floodgate ;;
	*) die "no such choice: $choice" ;;
	esac
fi
case $server_type in
java) wanted_mods=(fabric-api) ;;
geyser) wanted_mods=(fabric-api geyser) ;;
floodgate) wanted_mods=(fabric-api geyser floodgate) ;;
*) die "--type must be java, geyser or floodgate" ;;
esac
[[ $server_type == java ]] || read_geyser_ports

# A rerun keeps the cap the last run set.
[[ -n $heap ]] || heap=$previous_heap
[[ $heap != auto ]] || heap=''
if [[ -z $heap ]]; then
	mem_mb=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))
	heap_mb=$((mem_mb / 2))
	((heap_mb < 1024)) && heap_mb=1024
	((heap_mb > 4096)) && heap_mb=4096
	if ((heap_mb % 1024)); then heap=${heap_mb}M; else heap=$((heap_mb / 1024))G; fi
fi
heap_mb=$((10#${heap%[GgMm]}))
[[ $heap == *[Gg] ]] && heap_mb=$((heap_mb * 1024))
((heap_mb >= 512)) || die "a heap of $heap is too small for a Minecraft server; use at least 512M"
# The JVM refuses to start when -Xms exceeds -Xmx.
if ((heap_mb < 1024)); then initial_heap=$heap; else initial_heap=1G; fi

# --- resolve everything before touching the host ----------------------------

info "Resolving versions for Minecraft $mc_version"
# Fabric's version list includes IDs with spaces (old pre-releases).
mc_url=$(python3 -Ic 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$mc_version")
loaders=$(fetch "$FABRIC_META/versions/loader/$mc_url") || die "Fabric loader lookup failed"
loader_version=$(json 'next((x["loader"]["version"] for x in d if x["loader"]["stable"]), d[0]["loader"]["version"] if d else "")' <<<"$loaders") || loader_version=''
[[ -n $loader_version ]] || die "Fabric meta lists no loader for Minecraft $mc_version"
installers=$(fetch "$FABRIC_META/versions/installer") || die "Fabric installer lookup failed"
installer_version=$(json 'next((x["version"] for x in d if x["stable"]), d[0]["version"] if d else "")' <<<"$installers") || installer_version=''
[[ -n $installer_version ]] || die "Fabric meta lists no installer versions"

manifest=$(fetch "$MOJANG_MANIFEST") || die "can't reach Mojang's version manifest"
version_url=$(json 'next(v["url"] for v in d["versions"] if v["id"] == sys.argv[1])' "$mc_version" <<<"$manifest") ||
	die "Mojang's manifest has no $mc_version"
version_json=$(fetch "$version_url") || die "Mojang version lookup failed"
# Versions older than 1.17 don't state it; they run on Java 8.
java_required=$(json 'd.get("javaVersion", {}).get("majorVersion", 8)' <<<"$version_json") ||
	die "unexpected answer from Mojang for $mc_version"

# mod_files[slug]=filename<TAB>sha512<TAB>url<TAB>version<TAB>version_type
declare -A mod_files
unavailable=()
for slug in "${wanted_mods[@]}"; do
	versions=$(fetch -G "$MODRINTH/project/$slug/version" \
		--data-urlencode 'loaders=["fabric"]' \
		--data-urlencode "game_versions=[\"$mc_version\"]") || die "Modrinth lookup failed: $slug"
	# The newest release, or a beta or alpha only when there's no release.
	# Geyser is the exception: GeyserMC labels its whole build stream "beta",
	# so its newest build is the one to run (NetherNet fixes land there).
	line=$(python3 -Ic '
import json, sys
vs = sorted(json.load(sys.stdin), key=lambda v: v["date_published"], reverse=True)
pick = vs if sys.argv[1] == "geyser" else [v for v in vs if v["version_type"] == "release"] or vs
v = pick[0] if pick else None
if v:
    f = next((x for x in v["files"] if x["primary"]), v["files"][0])
    print("\t".join((f["filename"], f["hashes"]["sha512"], f["url"], v["version_number"], v["version_type"])))' "$slug" <<<"$versions")
	if [[ -z $line ]]; then
		unavailable+=("$slug")
	else
		# The filename becomes a path under mods/ (written as root in system
		# mode): accept only a plain jar name from the API, nothing path-like.
		IFS=$'\t' read -r filename _ <<<"$line"
		[[ $filename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.jar$ ]] || die "Modrinth returned an unexpected filename for $slug: $filename"
		mod_files[$slug]=$line
	fi
done
if ((${#unavailable[@]})); then
	die "no Fabric build of ${unavailable[*]} for Minecraft $mc_version on Modrinth; pick another version or server type"
fi
if [[ -n ${mod_files[geyser]:-} ]]; then
	IFS=$'\t' read -r _ _ _ geyser_version _ <<<"${mod_files[geyser]}"
	if [[ ! $geyser_version =~ -b([0-9]+)$ ]] || ((BASH_REMATCH[1] < 1237)); then
		warn "Geyser $geyser_version predates NetherNet (build 1237): Bedrock clients from 26.60 (2026-10-27) on can't join it."
	fi
fi

# java_major BIN — print the Java major version (8 for "1.8.0_x").
java_major() {
	local out
	out=$("$1" -version 2>&1) || return 1
	[[ $out =~ version\ \"([0-9]+)(\.([0-9]+))? ]] || return 1
	if [[ ${BASH_REMATCH[1]} == 1 ]]; then echo "${BASH_REMATCH[3]}"; else echo "${BASH_REMATCH[1]}"; fi
}

# usable_java BIN — a system unit runs as $SYSTEM_USER, which can't reach a
# JVM inside someone's home directory (SDKMAN, a JAVA_HOME under ~).
usable_java() {
	[[ -n $1 && -x $1 ]] || return 1
	[[ $service_mode == system ]] || return 0
	! in_home "$1"
}

# find_java — set java_bin/java_found to the oldest Java >= java_required,
# closest to what Mojang tested (very new JVMs can break old versions).
# JAVA_HOME and PATH come first, so they win a tie.
find_java() {
	local bin major best='' best_major=''
	for bin in ${JAVA_HOME:+"$JAVA_HOME/bin/java"} "$(command -v java || true)" /usr/lib/jvm/*/bin/java /usr/lib64/jvm/*/bin/java; do
		usable_java "$bin" || continue
		# Absolute (symlinks kept): it goes into ExecStart and start.sh.
		bin=$(realpath -sm -- "$bin")
		major=$(java_major "$bin") || continue
		if ((major >= java_required)) && [[ -z $best || $major -lt $best_major ]]; then
			best=$bin best_major=$major
		fi
	done
	[[ -n $best ]] || return 1
	java_bin=$best java_found=$best_major
}

if ! find_java; then
	[[ -n $pm ]] || die "Minecraft $mc_version needs Java $java_required or newer; install it and rerun"
	case $pm in
	pacman) candidates=("jre$java_required-openjdk-headless" jre-openjdk-headless) ;;
	apt-get) candidates=("openjdk-$java_required-jre-headless") ;;
	dnf) candidates=("java-$java_required-openjdk-headless" java-latest-openjdk-headless) ;;
	zypper) candidates=("java-$java_required-openjdk-headless") ;;
	esac
	apt_update_once
	java_pkg=
	for p in "${candidates[@]}"; do
		pkg_available "$p" && {
			java_pkg=$p
			break
		}
	done
	[[ -n $java_pkg ]] || die "Minecraft $mc_version needs Java $java_required+, and $pm has none of: ${candidates[*]}"
	confirm "Minecraft $mc_version needs Java $java_required or newer. Install $java_pkg with $pm?" y ||
		die "Java $java_required+ is required"
	pkg_install "$java_pkg"
	find_java || die "installed $java_pkg but still can't find Java $java_required+"
fi

# Aikar's G1GC flags minus the ones Java 27 rejects or deprecates
# (ParallelRefProcEnabled, G1RSetUpdatingPauseIntervalMillis,
# InitiatingHeapOccupancyPercent), and minus -Xms=-Xmx and AlwaysPreTouch,
# which assume a dedicated host: the heap starts small and grows to the cap.
java_args=(-Xms"$initial_heap" -Xmx"$heap" -XX:+UseG1GC -XX:MaxGCPauseMillis=200
	-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30
	-XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20
	-XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4
	-XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem
	-XX:MaxTenuringThreshold=1 -jar fabric-server-launch.jar nogui)
# Geyser's bundled Gson sets final fields reflectively, which newer JVMs warn
# about and say a future release will block. Only JVMs that know the flag
# accept it; older ones refuse to start, so probe rather than guess.
if "$java_bin" --enable-final-field-mutation=ALL-UNNAMED -version >/dev/null 2>&1; then
	java_args=(--enable-final-field-mutation=ALL-UNNAMED "${java_args[@]}")
fi
# Bedrock 26.60 (2026-10-27) drops RakNet, which Geyser still defaults to.
# Geyser builds from 1237 read this property over their config and speak
# NetherNet instead: signaling on TCP and gameplay on UDP, both on 19132.
if [[ $server_type != java ]]; then
	java_args=(-DgeyserTransport=nethernet "${java_args[@]}")
fi

# --- existing install --------------------------------------------------------

unit_file_for() {
	if [[ $1 == user ]]; then
		echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"
	else
		echo "/etc/systemd/system/$UNIT_NAME"
	fi
}
unit_path=''
[[ $service_mode == none ]] || unit_path=$(unit_file_for "$service_mode")

# Jar name patterns of the mods this script manages.
declare -A mod_patterns=(
	["fabric-api"]='fabric-api-[0-9]*.jar'
	[geyser]='Geyser-Fabric-*.jar'
	[floodgate]='Floodgate-Fabric-*.jar'
)

# Never delete or overwrite an unrecorded custom build. A matching upstream
# artifact can be adopted, including installations made before the state file.
for slug in "${wanted_mods[@]}"; do
	IFS=$'\t' read -r filename sha512 _ <<<"${mod_files[$slug]}"
	peek test -d "$server_dir/mods" || continue
	jars=$(peek find "$server_dir/mods" -maxdepth 1 -iname "${mod_patterns[$slug]}" -printf '%f\n') ||
		die "can't inspect existing mods in $server_dir"
	while IFS= read -r old; do
		[[ -n $old ]] || continue
		managed=false
		for recorded in "${previous_jars[@]}"; do
			[[ $old != "$recorded" ]] || managed=true
		done
		$managed && continue
		if [[ $old == "$filename" ]] && peek sha512sum -c --status <<<"$sha512  $server_dir/mods/$old"; then
			continue
		fi
		die "unmanaged mods/$old conflicts with $slug; move it out of mods/ before rerunning (it has been left untouched)"
	done <<<"$jars"
done

# --- confirm -----------------------------------------------------------------

mods_summary=
for slug in "${wanted_mods[@]}"; do
	IFS=$'\t' read -r _ _ _ v vtype <<<"${mod_files[$slug]}"
	mods_summary+="$slug $v$([[ $vtype == release ]] || echo " ($vtype)"), "
done
cat <<EOF

  Minecraft      $mc_version (Fabric loader $loader_version, installer $installer_version)
  Mods           ${mods_summary%, }
  Java           $java_bin (Java $java_found; $mc_version needs $java_required+)
  Heap           $initial_heap growing to $heap
  Directory      $server_dir${previous_version:+ (existing install: $previous_version)}
  Runs as        $(case $service_mode in
	user) echo "systemd user unit $unit_path" ;;
	system) echo "systemd system unit $unit_path, user $SYSTEM_USER" ;;
	none) echo "start.sh only" ;;
	esac)
  Ports          TCP $java_port$([[ $server_type == java ]] || echo ", UDP $bedrock_port$(if ((signaling_port)); then echo ", TCP $signaling_port"; fi) (Bedrock over NetherNet)")

EOF

if [[ -n $previous_version && $previous_version != "$mc_version" ]]; then
	warn "this directory's world was last run on $previous_version. Moving to a different version can't be undone, and a downgrade can corrupt the world. Back up world/ first. Other jars in mods/ may not support $mc_version."
	confirm "Switch $server_dir from $previous_version to $mc_version?" n || die "cancelled"
fi

if [[ -n $unit_path && -f $unit_path ]]; then
	unit_dir=$(sed -n 's/^WorkingDirectory=//p' "$unit_path")
	if [[ -n $unit_dir && $unit_dir != "$server_dir" ]]; then
		warn "$unit_path already runs a server in $unit_dir; continuing points it at $server_dir instead."
		confirm "Replace that unit?" n || die "cancelled"
	fi
fi

if ! $accept_eula && ! peek grep -qx 'eula=true' "$server_dir/eula.txt"; then
	if confirm "Do you agree to the Minecraft EULA (https://aka.ms/MinecraftEULA)? The server won't start without it" n; then
		accept_eula=true
	fi
fi
confirm "Proceed with the install?" y || die "cancelled"

# --- apply -------------------------------------------------------------------

if [[ $service_mode == system ]]; then
	sudo -v
	if ! id -u "$SYSTEM_USER" >/dev/null 2>&1; then
		info "Creating system user $SYSTEM_USER"
		sudo useradd --system --user-group --home-dir "$server_dir" --no-create-home \
			--shell "$(command -v nologin || echo /bin/false)" "$SYSTEM_USER"
	fi
	# An existing $SYSTEM_USER may have another primary group.
	system_group=$(id -gn "$SYSTEM_USER")
fi

# Download and verify everything before stopping or replacing anything, so
# a failed download leaves the current install untouched (and running).
if [[ $previous_version == "$mc_version" && $previous_launcher == "$loader_version/$installer_version" ]] &&
	as_owner test -s "$server_dir/fabric-server-launch.jar" 2>/dev/null; then
	info "Fabric server launcher (loader $loader_version, installer $installer_version) already present"
else
	info "Fabric server launcher (loader $loader_version, installer $installer_version)"
	fetch -o "$tmp/launcher.jar" \
		"$FABRIC_META/versions/loader/$mc_url/$loader_version/$installer_version/server/jar"
fi
mkdir "$tmp/mods"
for slug in "${wanted_mods[@]}"; do
	IFS=$'\t' read -r filename sha512 url version _ <<<"${mod_files[$slug]}"
	if as_owner sha512sum -c --status <<<"$sha512  $server_dir/mods/$filename" 2>/dev/null; then
		info "$slug $version already present"
		continue
	fi
	info "$slug $version -> mods/$filename"
	fetch -o "$tmp/mods/$filename" "$url"
	sha512sum -c --quiet <<<"$sha512  $tmp/mods/$filename" || die "$filename failed its SHA-512 check"
done

# ctl_in user|system ARGS... — systemctl in either scope.
ctl_in() {
	local scope=$1
	shift
	if [[ $scope == user ]]; then systemctl --user "$@"; else sudo systemctl "$@"; fi
}
service_ctl() { ctl_in "$service_mode" "$@"; }
# Reading ActiveState needs no root. Include queued restarts and shutdowns.
state_in() {
	if [[ $1 == user ]]; then systemctl --user show -p ActiveState --value "$UNIT_NAME"; else systemctl show -p ActiveState --value "$UNIT_NAME"; fi
}
active_in() {
	local state
	state=$(state_in "$1") || return 1
	[[ -n $state && $state != inactive && $state != failed ]]
}
user_bus=false
systemctl --user show-environment >/dev/null 2>&1 && user_bus=true

# Stop whatever runs this directory, in either scope, before anything in it
# changes hands or gets replaced. A unit of the other mode serving the same
# directory would start a second server on the world, so offer to remove it.
# The unit of the chosen mode is about to be rewritten (already confirmed if
# it served another directory), so it's stopped whatever it serves.
# serving_unit_active — a unit in either scope runs a server in this
# directory (it then holds the ports itself, and is stopped below).
serving_unit_active() {
	local scope file
	for scope in user system; do
		file=$(unit_file_for "$scope")
		[[ -f $file && $(sed -n 's/^WorkingDirectory=//p' "$file") == "$server_dir" ]] || continue
		active_in "$scope" 2>/dev/null && return 0
	done
	return 1
}
# Checked before any unit is stopped, so cancelling here changes nothing. A
# unit that is running holds these ports itself and is stopped below.
if ! command -v ss >/dev/null; then
	warn "ss (iproute2) isn't installed, so a server started from start.sh can't be detected; make sure none is running"
elif ! serving_unit_active && [[ -n $(ss -Hltn "sport = :$java_port" 2>/dev/null)$(
	if [[ $server_type != java ]]; then
		ss -Hlun "sport = :$bedrock_port" 2>/dev/null
		((signaling_port == 0)) || ss -Hltn "sport = :$signaling_port" 2>/dev/null
	fi
) ]]; then
	warn "something is already listening on a selected server port (Java TCP $java_port, Bedrock UDP $bedrock_port, signaling TCP $signaling_port). If it's this server running from start.sh, stop it first: updating jars under a running server can break it."
	confirm "Continue anyway?" n || die "cancelled"
fi

was_running=false stopped_units=()
if $have_systemd; then
	for scope in user system; do
		file=$(unit_file_for "$scope")
		[[ -f $file ]] || continue
		if [[ $scope != "$service_mode" ]]; then
			[[ $(sed -n 's/^WorkingDirectory=//p' "$file") == "$server_dir" ]] || continue
			# Without a user bus (su, some SSH logins) that unit can be
			# neither seen nor stopped, and it could be running right now.
			[[ $scope == system ]] || $user_bus ||
				die "$file also serves $server_dir, but there's no user systemd session here to stop or remove it; rerun from a normal login"
		fi
		state=$(state_in "$scope") || die "can't inspect the $scope unit $UNIT_NAME"
		[[ -n $state ]] || die "no state reported for the $scope unit $UNIT_NAME"
		if [[ $state != inactive && $state != failed ]]; then
			confirm "The $scope unit $UNIT_NAME is running. Stop it to update (players will be disconnected)?" y ||
				die "cancelled"
			stopped_units+=("$scope")
			was_running=true
		fi
		# Stop even an inactive unit to cancel queued jobs before any writes.
		ctl_in "$scope" stop "$UNIT_NAME"
		state=$(state_in "$scope") || die "can't verify the $scope unit stopped"
		[[ $state == inactive || $state == failed ]] || die "the $scope unit is still $state; refusing to update"
		if [[ $scope != "$service_mode" ]]; then
			if confirm "Disable and remove the old $scope unit $file for this directory?" y; then
				ctl_in "$scope" disable -q "$UNIT_NAME" || true
				if [[ $scope == user ]]; then rm -f "$file"; else sudo rm -f "$file"; fi
				ctl_in "$scope" daemon-reload
			else
				warn "$file still points at $server_dir; never run it beside the new $service_mode unit"
			fi
		fi
	done
fi

if [[ $service_mode == system ]]; then
	sudo install -d -o "$SYSTEM_USER" -g "$system_group" -m 750 "$server_dir"
	if [[ -n $dir_owner && $dir_owner != "$SYSTEM_USER" ]]; then
		sudo chown -R "$SYSTEM_USER:$system_group" "$server_dir"
	fi
else
	mkdir -p "$server_dir"
fi
as_owner mkdir -p "$server_dir/mods"

artifacts_pending=true
if [[ -f $tmp/launcher.jar ]]; then
	remember_artifact "$server_dir/fabric-server-launch.jar"
	place "$tmp/launcher.jar" "$server_dir/fabric-server-launch.jar" 644
fi
# Install all replacements before removing any previously managed versions.
for slug in "${wanted_mods[@]}"; do
	IFS=$'\t' read -r filename _ <<<"${mod_files[$slug]}"
	if [[ -f $tmp/mods/$filename ]]; then
		remember_artifact "$server_dir/mods/$filename"
		place "$tmp/mods/$filename" "$server_dir/mods/$filename" 644
	fi
done

# Jars a previous run recorded but this one doesn't want (another version, or
# a mod dropped from the server type).
for old in "${previous_jars[@]}"; do
	keep=false
	for slug in "${wanted_mods[@]}"; do
		[[ ${mod_files[$slug]%%$'\t'*} != "$old" ]] || keep=true
	done
	if ! $keep && as_owner test -e "$server_dir/mods/$old"; then
		remember_artifact "$server_dir/mods/$old"
		as_owner rm -f -- "$server_dir/mods/$old"
		info "Removed mods/$old (no longer part of this '$server_type' server)"
	fi
done

remember_artifact "$server_dir/$STATE_FILE"
write_file "$server_dir/$STATE_FILE" 644 <<EOF
# Written by install.sh; read on rerun.
mc_version=$mc_version
server_type=$server_type
loader_version=$loader_version
installer_version=$installer_version
service_mode=$service_mode
heap=$heap
$(for slug in "${wanted_mods[@]}"; do printf 'mod_%s=%s\n' "$slug" "${mod_files[$slug]%%$'\t'*}"; done)
EOF
artifacts_pending=false

if $accept_eula; then
	echo "eula=true" | write_file "$server_dir/eula.txt" 644
elif ! as_owner test -f "$server_dir/eula.txt"; then
	echo "eula=false" | write_file "$server_dir/eula.txt" 644
fi

if ! as_owner test -f "$server_dir/server.properties"; then
	# Minecraft fills in every other key with its defaults on first start.
	case $server_type in
	java) motd="Fabric $mc_version" ;;
	geyser) motd="Fabric $mc_version + Geyser" ;;
	floodgate) motd="Fabric $mc_version + Geyser + Floodgate" ;;
	esac
	write_file "$server_dir/server.properties" 644 <<EOF
server-port=$JAVA_PORT
online-mode=true
max-players=10
white-list=false
view-distance=10
simulation-distance=10
motd=$motd
EOF
fi

# Geyser writes its config on first start with auth-type: online. With
# Floodgate, point it at Floodgate (key.pem is shared automatically on the
# same server); without, put it back to online in case Floodgate was dropped.
geyser_config=$server_dir/config/Geyser-Fabric/config.yml
set_geyser_auth() {
	as_owner test -f "$geyser_config" || return 1
	as_owner sed -i -E "s/^(\s*auth-type:).*/\1 $1/" "$geyser_config"
	as_owner grep -qE "^\s*auth-type: $1\s*$" "$geyser_config" ||
		die "couldn't set auth-type: $1 in $geyser_config (has its layout changed?); set it by hand"
}
case $server_type in
floodgate) set_geyser_auth floodgate || needs_first_boot=true ;;
geyser) set_geyser_auth online || true ;;
esac

# systemd_quote ARG... — join arguments for a unit file. systemd has its own
# command-line syntax: double quotes with C-style escapes, "%" starts a
# specifier and "$" an environment variable, so bash's %q won't do.
systemd_quote() {
	local a out=()
	for a; do
		a=${a//%/%%}
		a=${a//\$/\$\$}
		if [[ ! $a =~ ^[A-Za-z0-9_@+=:,./-]+$ ]]; then
			a=${a//\\/\\\\}
			a="\"${a//\"/\\\"}\""
		fi
		out+=("$a")
	done
	printf '%s' "${out[*]}"
}

# The launcher command, shared by the unit and start.sh so they never drift.
printf -v java_cmd '%q ' "$java_bin" "${java_args[@]}"
java_cmd=${java_cmd% }

{
	cat <<EOF
#!/usr/bin/env bash
# Generated by install.sh — edits are lost on rerun.
# Runs the server in this terminal with its console; type "stop" to quit.
set -euo pipefail
EOF
	if [[ $service_mode == system ]]; then
		cat <<EOF
if [[ \$(id -un) != $SYSTEM_USER ]]; then
	echo "run this as $SYSTEM_USER: sudo -u $SYSTEM_USER $(printf %q "$server_dir/start.sh" | sed 's/[\\"$`]/\\&/g')" >&2
	exit 1
fi
EOF
	fi
	# Two servers on one world corrupt it, so refuse beside the service, in
	# either scope and in every mode (a unit kept from an earlier mode too).
	cat <<EOF
case \$(systemctl --user show -p ActiveState --value $UNIT_NAME 2>/dev/null) in
active|activating|reloading|deactivating|refreshing)
	echo "$UNIT_NAME (user) is running; stop it first: systemctl --user stop $UNIT_NAME" >&2
	exit 1
	;;
esac
case \$(systemctl show -p ActiveState --value $UNIT_NAME 2>/dev/null) in
active|activating|reloading|deactivating|refreshing)
	echo "$UNIT_NAME (system) is running; stop it first: sudo systemctl stop $UNIT_NAME" >&2
	exit 1
	;;
esac
EOF
	cat <<EOF
cd "\$(dirname "\$(readlink -f "\${BASH_SOURCE[0]}")")"
exec $java_cmd
EOF
} | write_file "$server_dir/start.sh" 755

if [[ $service_mode != none ]]; then
	if [[ $service_mode == system ]]; then
		hardening="User=$SYSTEM_USER
Group=$system_group
# The user may predate this directory (its passwd home elsewhere).
Environment=$(systemd_quote "HOME=$server_dir")
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$(systemd_quote "$server_dir")"
		wanted_by=multi-user.target
		# The user manager has no network-online.target; only system units
		# can wait for the network.
		ordering="Wants=network-online.target
After=network-online.target"
	else
		ordering=
		hardening=
		wanted_by=default.target
	fi
	unit=$(
		cat <<EOF
[Unit]
Description=Minecraft $mc_version Fabric server ($server_type)
${ordering}

[Service]
WorkingDirectory=$server_dir
ExecStart=$(systemd_quote "$java_bin" "${java_args[@]}")
# The JVM's shutdown hook saves the world on SIGTERM; give it time. The JVM
# then exits 128+15=143, which is a clean stop, not a failure.
TimeoutStopSec=90
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
${hardening}

[Install]
WantedBy=$wanted_by
EOF
	)
	if [[ $service_mode == system ]]; then
		sudo tee "$unit_path" >/dev/null <<<"$unit"
		sudo systemctl daemon-reload
	else
		mkdir -p "$(dirname "$unit_path")"
		cat >"$unit_path" <<<"$unit"
		systemctl --user daemon-reload
	fi
fi

# --- firewall ----------------------------------------------------------------

ports=("$java_port/tcp")
if [[ $server_type != java ]]; then
	ports+=("$bedrock_port/udp")
	((signaling_port == 0)) || ports+=("$signaling_port/tcp")
fi
if systemctl is-active -q firewalld 2>/dev/null; then
	if confirm "firewalld is active. Open ${ports[*]} permanently in its default zone?" n; then
		for p in "${ports[@]}"; do sudo firewall-cmd -q --permanent --add-port="$p"; done
		sudo firewall-cmd -q --reload
		info "Opened ${ports[*]}; undo with: sudo firewall-cmd --permanent --remove-port=PORT/PROTO && sudo firewall-cmd --reload"
	fi
elif systemctl is-active -q ufw 2>/dev/null && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
	if confirm "ufw is active. Allow ${ports[*]}?" n; then
		for p in "${ports[@]}"; do sudo ufw allow "$p"; done
		info "Allowed ${ports[*]}; undo with: sudo ufw delete allow PORT/PROTO"
	fi
fi

# --- first boot --------------------------------------------------------------

# Floodgate needs Geyser's config, which only exists after a first start.
# Boot once in the background, wait for "Done", stop it, then finish.
alive() {
	local stat
	stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
	[[ ${stat##*) } != Z* ]]
}
boot_pidfile='' boot_java_pid=''
# shut_down_boot — SIGTERM the JVM, whose shutdown hook saves the world (the
# same way systemd stops the unit); kill it if that takes over 2 minutes.
# Never leave this server running: a later start would put a second one on
# the same world.
shut_down_boot() {
	local wait_until=$((SECONDS + 120)) java_pid=${boot_java_pid:-}
	[[ -n $boot_pid ]] || return 0
	[[ -n $java_pid ]] || java_pid=$(as_owner cat "$boot_pidfile" 2>/dev/null || true)
	# Without a PID (interrupted within the first moments), signal the
	# wrapper instead: outside system mode it has exec'd into java and is the
	# JVM; in system mode it is sudo (root), which relays signals to java.
	signal_boot() {
		if [[ -n $java_pid ]]; then
			as_owner kill "-$1" "$java_pid"
		elif [[ $service_mode == system ]]; then
			sudo kill "-$1" "$boot_pid"
		else
			kill "-$1" "$boot_pid"
		fi 2>/dev/null || true
	}
	boot_alive() {
		alive "$boot_pid" || { [[ -n $java_pid ]] && alive "$java_pid"; }
	}
	signal_boot TERM
	while boot_alive && ((SECONDS < wait_until)); do sleep 1; done
	if boot_alive; then
		warn "the server didn't stop within 2 minutes; killing it"
		signal_boot KILL
		wait_until=$((SECONDS + 15))
		while boot_alive && ((SECONDS < wait_until)); do sleep 1; done
		if boot_alive; then
			boot_stop_failed=true
			warn "couldn't stop the first-boot server (PID ${java_pid:-$boot_pid}); stop it by hand before starting another"
			return 1
		fi
	fi
	as_owner rm -f "$boot_pidfile"
	wait "$boot_pid" 2>/dev/null || true
	boot_pid=''
}
first_boot() {
	local log=$tmp/first-boot.log deadline=$((SECONDS + 600))
	boot_pidfile=$server_dir/.first-boot.pid
	: >"$log"
	info "First boot: generating the world and configs (can take a few minutes)"
	# The global EXIT trap stops this JVM on errors, Ctrl-C or a dropped SSH session.
	# A PID left by an interrupted earlier run could belong to anything now.
	as_owner rm -f "$boot_pidfile"
	# The wrapper records the JVM's own PID (it execs into java), so it can
	# be signalled without guessing at process names. Launched directly, not
	# through as_owner, so $! is that wrapper itself (or, in system mode, the
	# sudo that relays signals to it) rather than a function's subshell.
	# shellcheck disable=SC2016 # the inner script's $ expand in that shell
	local wrapper=(bash -c 'cd "$1" && echo $$ >"$2" && shift 2 && exec "$@"'
		_ "$server_dir" "$boot_pidfile" "$java_bin" "${java_args[@]}")
	if [[ $service_mode == system ]]; then
		(cd / && exec sudo -u "$SYSTEM_USER" "${wrapper[@]}") </dev/null >"$log" 2>&1 &
	else
		"${wrapper[@]}" </dev/null >"$log" 2>&1 &
	fi
	boot_pid=$!
	# Read the JVM's PID now, while sudo's credentials are fresh.
	boot_java_pid=''
	for _ in {1..20}; do
		boot_java_pid=$(as_owner cat "$boot_pidfile" 2>/dev/null || true)
		[[ -z $boot_java_pid ]] || break
		sleep 0.5
	done
	until grep -qE 'Done \([0-9.]+s\)!' "$log"; do
		# Keep sudo's timestamp alive so shutting down never needs a prompt.
		[[ $service_mode != system ]] || sudo -n -v 2>/dev/null || true
		if ! alive "$boot_pid"; then
			shut_down_boot
			tail -n 20 "$log" >&2
			die "the server exited during its first boot (log above)"
		fi
		if ((SECONDS > deadline)); then
			shut_down_boot
			tail -n 20 "$log" >&2
			die "first boot didn't finish within 10 minutes (log above)"
		fi
		sleep 2
	done
	shut_down_boot
}

if ${needs_first_boot:-false}; then
	if ! as_owner grep -qx 'eula=true' "$server_dir/eula.txt"; then
		warn "Floodgate setup is unfinished: accept the EULA, start the server once, stop it, then rerun this script."
	elif confirm "Boot the server once now to finish Floodgate setup?" y; then
		# Refresh sudo in the foreground: the boot runs in the background.
		[[ $service_mode != system ]] || sudo -v
		first_boot
		set_geyser_auth floodgate || die "Geyser didn't write $geyser_config on first boot"
		info "Geyser now uses Floodgate auth"
	else
		warn "Floodgate setup is unfinished: start the server once, stop it, then rerun this script."
	fi
fi

# --- start -------------------------------------------------------------------

if [[ $service_mode != none ]] && as_owner grep -qx 'eula=true' "$server_dir/eula.txt"; then
	if [[ $service_mode == user ]]; then
		autostart_q="Start the server automatically at boot (enables the unit and lingering for $me)?"
	else
		autostart_q="Start the server automatically at boot?"
	fi
	enabled=n
	if [[ $service_mode == user ]]; then
		systemctl --user is-enabled -q "$UNIT_NAME" 2>/dev/null && enabled=y
	else
		systemctl is-enabled -q "$UNIT_NAME" 2>/dev/null && enabled=y
	fi
	if confirm "$autostart_q" "$enabled"; then
		service_ctl enable -q "$UNIT_NAME"
		if [[ $service_mode == user ]] && ! loginctl enable-linger "$me"; then
			warn "couldn't enable lingering, so the server only runs while you're logged in; run: loginctl enable-linger $me"
		fi
	elif [[ $enabled == y ]]; then
		# Lingering is left alone: other user services may rely on it.
		service_ctl disable -q "$UNIT_NAME"
	fi
	if confirm "Start the server now?" "$($was_running && echo y || echo n)"; then
		service_ctl start "$UNIT_NAME"
	fi
fi

if [[ $service_mode == none ]] && $was_running; then
	warn "the server's old unit was stopped for this update; start it again with start.sh"
fi

finished=true

addresses=$(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | paste -sd' ' || true)
cat <<EOF

Done: Minecraft $mc_version Fabric server in $server_dir
  Java players:    ${addresses:-<this host>} port $java_port
EOF
if [[ $server_type != java ]]; then
	echo "  Bedrock gameplay: ${addresses:-<this host>} UDP $bedrock_port"
	if ((signaling_port)); then
		echo "  Bedrock signaling: ${addresses:-<this host>} TCP $signaling_port"
	else
		echo "  Bedrock signaling: external NXS service (no separate TCP listener)"
	fi
fi
case $service_mode in
user)
	echo "  Manage:          systemctl --user start|stop|status $UNIT_NAME; journalctl --user -u $UNIT_NAME -f"
	echo "  Console:         $(printf %q "$server_dir/start.sh") (with the service stopped)"
	;;
system)
	echo "  Manage:          sudo systemctl start|stop|status $UNIT_NAME; journalctl -u $UNIT_NAME -f"
	echo "  Console:         sudo -u $SYSTEM_USER $(printf %q "$server_dir/start.sh") (with the service stopped)"
	;;
none) echo "  Console:         $(printf %q "$server_dir/start.sh")" ;;
esac
as_owner grep -qx 'eula=true' "$server_dir/eula.txt" ||
	echo "  The EULA isn't accepted yet: rerun with --accept-eula before starting."
