#!/usr/bin/env bash
# Install or update a standalone Fabric Minecraft server, optionally with Geyser
# and Floodgate for Bedrock clients. Reruns update the launcher and managed mods
# and keep the world. Run it as a normal user; see --help for the options.
# Docs: docs/minecraft-fabric-server.md
set -euo pipefail

readonly FABRIC_META=https://meta.fabricmc.net/v2
readonly MODRINTH=https://api.modrinth.com/v2
readonly MOJANG_MANIFEST=https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
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
	cat <<'EOF'
Usage: install.sh [options]
  --mc-version VER   Minecraft version, e.g. 26.3 (default: latest stable)
  --type TYPE        java | geyser | floodgate (geyser + floodgate)
  --service MODE     user | system | none
  --dir DIR          server directory
  --heap SIZE        max Java heap, e.g. 4G or 3072M; "auto" is half of RAM
                     between 1G and 4G (default: the last run's value, else auto)
  --accept-eula      agree to https://aka.ms/MinecraftEULA (eula=true)
  --yes              take the default for every unanswered question
                     (never accepts the EULA or opens the firewall)

Run it as a normal user. sudo is needed only for a system unit, package
installs, firewall changes, stopping a system unit for this directory and
reading an existing server directory you can't read.
Java listens on TCP 25565; Geyser on UDP 19132 for gameplay and TCP 19132
for NetherNet signaling.
EOF
}

mc_version='' server_type='' service_mode='' server_dir='' heap='' choice=''
accept_eula=false assume_yes=false
declare -A option_vars=(["--mc-version"]=mc_version ["--type"]=server_type ["--service"]=service_mode ["--dir"]=server_dir ["--heap"]=heap)
while (($#)); do
	case $1 in
	--mc-version | --type | --service | --dir | --heap)
		[[ -n ${2:-} && $2 != --* ]] || die "$1 needs a value"
		printf -v "${option_vars[$1]}" '%s' "$2"
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

ask() {
	local ask_reply=''
	if ! $assume_yes; then
		{ : </dev/tty; } 2>/dev/null || die "no terminal to ask on; pass the options and --yes"
		read -r -p "$2 [$3]: " ask_reply </dev/tty
	fi
	printf -v "$1" '%s' "${ask_reply:-$3}"
}

confirm() {
	local answer
	ask answer "$1 (y/n)" "$2"
	[[ ${answer,,} == y* ]]
}

pick() {
	local target=$1 previous=$2 default=$3 i
	shift 3
	for ((i = 1; i <= $#; i++)); do
		[[ ${!i} != "$previous" ]] || default=$i
	done
	ask choice "Choose 1-$#" "$default"
	[[ $choice == [1-$#] ]] || die "no such choice: $choice"
	printf -v "$target" '%s' "${!choice}"
}

as_owner() {
	if [[ $service_mode == system ]]; then
		(cd / && sudo -u "$SYSTEM_USER" "$@")
	else
		"$@"
	fi
}

# Every step runs as the owner: root never writes inside a system-mode tree (symlink races).
place() (
	place_staged=$(as_owner mktemp "$(dirname "$2")/.install-file.XXXXXX") || return
	trap '[[ -z "$place_staged" ]] || as_owner rm -f -- "$place_staged" || true' EXIT
	as_owner tee -- "$place_staged" <"$1" >/dev/null || return
	as_owner chmod -- "$3" "$place_staged" || return
	as_owner mv -fT -- "$place_staged" "$2" || return
	place_staged=""
)

remember_artifact() {
	local dest=$1 backup='' mode=''
	[[ ! ${saved_artifacts[$dest]+saved} ]] || return 0
	if as_owner test -L "$dest"; then
		backup=$tmp/artifact.${#artifact_paths[@]} mode=link
		as_owner readlink -- "$dest" >"$backup" || return
	elif as_owner test -e "$dest"; then
		backup=$tmp/artifact.${#artifact_paths[@]}
		mode=$(as_owner stat -c %a -- "$dest") || return
		as_owner cat -- "$dest" >"$backup" || return
	fi
	printf '%s\t%s\t%s\n' "$dest" "$backup" "$mode" >>"$tmp/recovery-map"
	saved_artifacts[$dest]=1
	artifact_paths+=("$dest") artifact_backups+=("$backup") artifact_modes+=("$mode")
}
rollback_artifacts() {
	local i failed=false
	for ((i = ${#artifact_paths[@]} - 1; i >= 0; i--)); do
		if [[ ${artifact_modes[i]} == link ]]; then
			as_owner ln -sfnT -- "$(<"${artifact_backups[i]}")" "${artifact_paths[i]}" || failed=true
		elif [[ -n ${artifact_backups[i]} ]]; then
			place "${artifact_backups[i]}" "${artifact_paths[i]}" "${artifact_modes[i]}" || failed=true
		else
			as_owner rm -f -- "${artifact_paths[i]}" || failed=true
		fi
	done
	! $failed
}

write_file() {
	local staged
	staged=$(mktemp -p "$tmp")
	cat >"$staged"
	place "$staged" "$1" "$2"
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
	esac && sudo_ready=true
}

pm=''
for candidate in pacman apt-get dnf zypper; do
	command -v "$candidate" >/dev/null || continue
	pm=$candidate
	break
done
apt_updated=false
apt_update_once() {
	[[ $pm == apt-get && $apt_updated == false ]] || return 0
	sudo apt-get update
	apt_updated=true
}

sudo_ready=false
need_sudo() {
	command -v sudo >/dev/null || die "sudo isn't installed, and it's needed to $1; install it, or do that by hand and rerun"
}

missing=()
for cmd in curl python3 sha512sum; do
	command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if ((${#missing[@]})); then
	[[ -n $pm ]] || die "missing: ${missing[*]}; install them and rerun"
	need_sudo "install ${missing[*]}"
	confirm "Missing ${missing[*]}. Install with $pm?" y || die "missing: ${missing[*]}"
	pkgs=("${missing[@]/sha512sum/coreutils}")
	[[ $pm != pacman ]] || pkgs=("${pkgs[@]/#python3/python}")
	apt_update_once
	pkg_install "${pkgs[@]}"
fi

tmp=$(mktemp -d)
boot_pid='' boot_stop_failed=false
artifacts_pending=false artifact_paths=() artifact_backups=() artifact_modes=()
declare -A saved_artifacts
finished=false stopped_units=()
on_exit() {
	local status=$? keep_tmp=false
	local -A start_hint=([user]="systemctl --user start $UNIT_NAME" [system]="sudo systemctl start $UNIT_NAME")
	if [[ -n $boot_pid ]] && { $boot_stop_failed || ! shut_down_boot; }; then
		warn "first-boot shutdown is unfinished; do not start another server. PID file: $boot_pidfile; logs: $tmp"
		status=1 keep_tmp=true
	fi
	if $artifacts_pending && rollback_artifacts; then
		warn "restored the previous launcher, managed mods and install state after the failed update"
	elif $artifacts_pending; then
		warn "artifact recovery failed; do not start the server. Backups and destination map are in $tmp"
		status=1 keep_tmp=true
	fi
	$keep_tmp || rm -rf "$tmp"
	if ! $finished && ((${#stopped_units[@]})) && $keep_tmp; then
		warn "the service was stopped; finish recovery before starting it again"
	elif ! $finished && ((${#stopped_units[@]})); then
		warn "the server was stopped for this update and is still down; rerun the installer before starting it with: ${start_hint[${stopped_units[0]}]}${stopped_units[1]:+, then ${start_hint[${stopped_units[1]}]}}"
	fi
	exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fetch() { curl -fsSL --proto =https --proto-redir =https -A "$USER_AGENT" "$@"; }

json() { python3 -Ic "import json, sys; d = json.load(sys.stdin); print($1)" "${@:2}"; }

game_versions=$(fetch "$FABRIC_META/versions/game") || die "can't reach meta.fabricmc.net"
latest=$(json 'next((g["version"] for g in d if g["stable"]), "")' <<<"$game_versions") || latest=''
[[ -n $latest ]] || die "unexpected answer from meta.fabricmc.net (no stable Minecraft versions)"

while :; do
	[[ -n $mc_version ]] || ask mc_version "Minecraft version" "$latest"
	json "any(g['version'] == sys.argv[1] for g in d)" "$mc_version" <<<"$game_versions" | grep -qx True && break
	recent=$(json '", ".join(g["version"] for g in d if g["stable"])' <<<"$game_versions" | cut -d, -f1-8)
	$assume_yes && die "Fabric doesn't support Minecraft '$mc_version'"
	warn "Fabric doesn't support Minecraft '$mc_version'. Recent releases: $recent, ..."
	mc_version=
done

dir_defaulted=false
if [[ -z $server_dir ]]; then
	default=/srv/minecraft-fabric
	[[ $service_mode == system ]] || [[ -z $service_mode && ! -e $HOME/minecraft-fabric && -e $default ]] || default=$HOME/minecraft-fabric
	ask server_dir "Server directory (an existing install there is updated)" "$default"
	[[ $server_dir != "$default" ]] || dir_defaulted=true
fi
case $server_dir in
\~ | \~/*) server_dir=$HOME${server_dir#\~} ;;
\~*) die "give the directory as an absolute path, not $server_dir" ;;
esac
server_dir=$(realpath -m -- "$server_dir")
# Plain characters only: the path goes into start.sh, a unit file and sudo command lines.
[[ $server_dir =~ ^[A-Za-z0-9\ _@+=:,./-]+$ ]] ||
	die "use a directory path of letters, digits, spaces and _@+=:,./- only: $server_dir"

in_home() {
	case $(realpath -m -- "$1")/ in
	"$(realpath -m /home)"/* | "$(realpath -m /root)"/* | "$(realpath -m "$HOME")"/*) return 0 ;;
	esac
	return 1
}

# CMD gets no stdin: it may run twice, and the first try would use it up.
peek() {
	"$@" </dev/null 2>/dev/null && return
	[[ -d $server_dir && ! (-r $server_dir && -x $server_dir) ]] || return 1
	sudo "$@" </dev/null 2>/dev/null
}

readonly YAML_WALK='
import re, sys
def walk(lines):
    stack = []
    for number, line in enumerate(lines, 1):
        match = re.fullmatch(r"( *)([\w-]+):(?:\s+(.*))?\s*", line.rstrip())
        if not match:
            continue
        indent, key, value = match.groups()
        while stack and stack[-1][0] >= len(indent):
            stack.pop()
        path = ".".join([k for _, k in stack] + [key])
        value = (value or "").split("#", 1)[0].strip()
        if not value:
            stack.append((len(indent), key))
        yield number, path, value
'
read_geyser_ports() {
	local config port
	config=$(peek cat "$server_dir/config/Geyser-Fabric/config.yml" || true)
	port=$(python3 -Ic "$YAML_WALK"'
settings = {}
for _, path, value in walk(sys.stdin):
    if value and path in ("bedrock", "bedrock.signaling"):
        sys.exit("Use block-style mappings for Geyser " + path)
    if value:
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
base = int(sys.argv[1]) if clone == "true" else base
udp = port("bedrock.webrtc-port", 0) or base
tcp = port("bedrock.signaling.port", 0) or base
mode = settings.get("bedrock.signaling.mode", "builtin")
if mode not in ("builtin", "hybrid", "nxs"):
    sys.exit("Invalid Geyser signaling mode: " + mode)
print(udp, 0 if mode == "nxs" or tcp == int(sys.argv[1]) else tcp)' "$java_port" "$BEDROCK_PORT" <<<"$config") ||
		die "couldn't resolve Geyser ports in $server_dir/config/Geyser-Fabric/config.yml"
	read -r bedrock_port signaling_port <<<"$port"
}

read_existing() {
	local state port
	previous_version='' previous_type='' previous_mode='' previous_launcher='' java_port=$JAVA_PORT
	previous_jars=() previous_heap='' bedrock_port=$BEDROCK_PORT signaling_port=$BEDROCK_PORT
	previous_floodgate_locale=''
	[[ -d $server_dir ]] || return 0
	[[ -r $server_dir && -x $server_dir ]] || info "Reading the existing install in $server_dir with sudo"
	state=$(peek cat "$server_dir/$STATE_FILE" || true)
	previous_version=$(sed -n 's/^mc_version=//p' <<<"$state")
	previous_type=$(sed -n 's/^server_type=//p' <<<"$state")
	previous_mode=$(sed -n 's/^service_mode=//p' <<<"$state")
	previous_launcher=$(sed -n 's/^\(loader\|installer\)_version=//p' <<<"$state" | paste -sd/)
	previous_heap=$(sed -n 's/^heap=\([1-9][0-9]*[GgMm]\)$/\1/p' <<<"$state")
	previous_floodgate_locale=$(sed -n 's/^floodgate_locale=\(set\)$/\1/p' <<<"$state")
	mapfile -t previous_jars < <(sed -n 's/^mod_[a-z-]*=\([A-Za-z0-9][A-Za-z0-9._+-]*\.jar\)$/\1/p' <<<"$state")
	[[ -n $previous_version ]] ||
		previous_version=$(peek find "$server_dir/versions" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
			sort -nr | head -n1 | cut -d' ' -f2- || true)
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
	pick service_mode "$previous_mode" "$($have_systemd && echo 1 || echo 3)" user system none
fi
[[ $service_mode == none ]] || $have_systemd || die "systemd isn't running here; use --service none"
[[ $service_mode != system ]] || need_sudo "run a system unit"
[[ $service_mode != user ]] || systemctl --user show-environment >/dev/null 2>&1 ||
	die "no systemd user session (common over su or some SSH setups); log in directly or use --service system"

case $service_mode:$server_dir/ in
system:/tmp/* | system:/var/tmp/*) die "a system-mode server can't live in $server_dir: the unit gives the server a private /tmp" ;;
esac
if [[ $service_mode == system ]] && in_home "$server_dir"; then
	$dir_defaulted && [[ ! -e $server_dir ]] ||
		die "a system-mode server can't live in a home directory ($server_dir); move it to e.g. /srv/minecraft-fabric first, or pick user mode"
	server_dir=/srv/minecraft-fabric
	info "System mode: using $server_dir instead"
	read_existing
fi
dir_owner=''
[[ ! -e $server_dir ]] || dir_owner=$(stat -c %U "$server_dir")
if [[ -n $dir_owner && $service_mode == system && $dir_owner != "$SYSTEM_USER" ]]; then
	# chown -R is only safe on a server directory, never on a mistyped /srv, /opt or /.
	[[ $(dirname "$server_dir") != / ]] ||
		die "refusing to hand the top-level directory $server_dir over to $SYSTEM_USER; use one inside it, e.g. $server_dir/minecraft-fabric"
	[[ -z $(sudo find "$server_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
		sudo test -f "$server_dir/server.properties" -o -f "$server_dir/$STATE_FILE" ||
		die "$server_dir isn't empty and doesn't look like a Minecraft server; refusing to hand it over to $SYSTEM_USER. Use a new directory such as $server_dir/minecraft-fabric"
	warn "$server_dir belongs to $dir_owner; a system-mode server needs it and everything in it owned by $SYSTEM_USER."
	confirm "Hand $server_dir over to $SYSTEM_USER?" y || die "cancelled"
elif [[ -n $dir_owner && $service_mode != system && $dir_owner != "$me" ]]; then
	die "$server_dir belongs to $dir_owner${previous_mode:+ (a $previous_mode-mode install)}; rerun with --service system, or take it over first: sudo chown -R $me: $(printf %q "$server_dir")"
elif [[ -z $dir_owner && $service_mode != system ]]; then
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
	pick server_type "$previous_type" 3 java geyser floodgate
fi
wanted_mods=(fabric-api)
[[ $server_type == java ]] || wanted_mods+=(geyser)
[[ $server_type != floodgate ]] || wanted_mods+=(floodgate)
[[ $server_type == java ]] || read_geyser_ports

[[ -n $heap ]] || heap=$previous_heap
[[ $heap != auto ]] || heap=''
if [[ -z $heap ]]; then
	heap_mb=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 2048))
	heap_mb=$((heap_mb < 1024 ? 1024 : heap_mb > 4096 ? 4096 : heap_mb))
	heap=$((heap_mb / 1024))G
	((heap_mb % 1024 == 0)) || heap=${heap_mb}M
fi
heap_mb=$((10#${heap%[GgMm]}))
[[ $heap == *[Gg] ]] && heap_mb=$((heap_mb * 1024))
((heap_mb >= 512)) || die "a heap of $heap is too small for a Minecraft server; use at least 512M"
if ((heap_mb < 1024)); then initial_heap=$heap; else initial_heap=1G; fi

info "Resolving versions for Minecraft $mc_version"
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
java_required=$(json 'd.get("javaVersion", {}).get("majorVersion", 8)' <<<"$version_json") ||
	die "unexpected answer from Mojang for $mc_version"

declare -A mod_files
unavailable=() mod_jars=()
for slug in "${wanted_mods[@]}"; do
	versions=$(fetch -G "$MODRINTH/project/$slug/version" \
		--data-urlencode 'loaders=["fabric"]' \
		--data-urlencode "game_versions=[\"$mc_version\"]") || die "Modrinth lookup failed: $slug"
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
		continue
	fi
	IFS=$'\t' read -r filename _ <<<"$line"
	# The filename becomes a path under mods/: accept only a plain jar name.
	[[ $filename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.jar$ ]] || die "Modrinth returned an unexpected filename for $slug: $filename"
	mod_files[$slug]=$line mod_jars+=("$filename")
done
((${#unavailable[@]} == 0)) || die "no Fabric build of ${unavailable[*]} for Minecraft $mc_version on Modrinth; pick another version or server type"
IFS=$'\t' read -r _ _ _ geyser_version _ <<<"${mod_files[geyser]:-}"
if [[ -n ${mod_files[geyser]:-} ]] && { [[ ! $geyser_version =~ -b([0-9]+)$ ]] || ((BASH_REMATCH[1] < 1237)); }; then
	warn "Geyser $geyser_version predates NetherNet (build 1237): Bedrock clients from 26.60 (2026-10-27) on can't join it."
fi

java_major() {
	local out
	out=$("$1" -version 2>&1) || return 1
	[[ $out =~ version\ \"([0-9]+)(\.([0-9]+))? ]] || return 1
	if [[ ${BASH_REMATCH[1]} == 1 ]]; then echo "${BASH_REMATCH[3]}"; else echo "${BASH_REMATCH[1]}"; fi
}

usable_java() {
	[[ -n $1 && -x $1 ]] || return 1
	[[ $service_mode == system ]] || return 0
	! in_home "$1"
}

find_java() {
	local bin major best='' best_major=''
	for bin in ${JAVA_HOME:+"$JAVA_HOME/bin/java"} "$(command -v java || true)" /usr/lib/jvm/*/bin/java /usr/lib64/jvm/*/bin/java; do
		usable_java "$bin" || continue
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
	need_sudo "install Java $java_required"
	case $pm in
	pacman) candidates=("jre$java_required-openjdk-headless" jre-openjdk-headless) ;;
	apt-get) candidates=("openjdk-$java_required-jre-headless") ;;
	dnf) candidates=("java-$java_required-openjdk-headless" java-latest-openjdk-headless) ;;
	zypper) candidates=("java-$java_required-openjdk-headless") ;;
	esac
	apt_update_once
	java_pkg=
	for p in "${candidates[@]}"; do
		pkg_available "$p" || continue
		java_pkg=$p
		break
	done
	[[ -n $java_pkg ]] || die "Minecraft $mc_version needs Java $java_required+, and $pm has none of: ${candidates[*]}"
	confirm "Minecraft $mc_version needs Java $java_required or newer. Install $java_pkg with $pm?" y ||
		die "Java $java_required+ is required"
	pkg_install "$java_pkg"
	find_java || die "installed $java_pkg but still can't find Java $java_required+"
fi

java_args=(-Xms"$initial_heap" -Xmx"$heap" -XX:+UseG1GC -XX:MaxGCPauseMillis=200
	-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30
	-XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20
	-XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4
	-XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem
	-XX:MaxTenuringThreshold=1 -jar fabric-server-launch.jar nogui)
! "$java_bin" --enable-final-field-mutation=ALL-UNNAMED -version >/dev/null 2>&1 ||
	java_args=(--enable-final-field-mutation=ALL-UNNAMED "${java_args[@]}")
[[ $server_type == java ]] || java_args=(-DgeyserTransport=nethernet "${java_args[@]}")

unit_file_for() {
	[[ $1 != user ]] || echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"
	[[ $1 == user ]] || echo "/etc/systemd/system/$UNIT_NAME"
}
unit_path=''
[[ $service_mode == none ]] || unit_path=$(unit_file_for "$service_mode")

declare -A mod_patterns=(
	["fabric-api"]='fabric-api-[0-9]*.jar'
	[geyser]='Geyser-Fabric-*.jar'
	[floodgate]='Floodgate-Fabric-*.jar'
)

recorded_jars=$(printf '/%s' "${previous_jars[@]}")/
for slug in "${wanted_mods[@]}"; do
	IFS=$'\t' read -r filename sha512 _ <<<"${mod_files[$slug]}"
	peek test -d "$server_dir/mods" || continue
	jars=$(peek find "$server_dir/mods" -maxdepth 1 -iname "${mod_patterns[$slug]}" -printf '%f\n') ||
		die "can't inspect existing mods in $server_dir"
	while IFS= read -r old; do
		[[ -n $old && $recorded_jars != *"/$old/"* ]] || continue
		[[ $old != "$filename" ]] || printf '%s  %s\n' "$sha512" "$server_dir/mods/$old" >"$tmp/adopt.sha512"
		[[ $old == "$filename" ]] && peek sha512sum -c --status "$tmp/adopt.sha512" && continue
		die "unmanaged mods/$old conflicts with $slug; move it out of mods/ before rerunning (it has been left untouched)"
	done <<<"$jars"
done

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

unit_dir=''
[[ -z $unit_path || ! -f $unit_path ]] || unit_dir=$(sed -n 's/^WorkingDirectory=//p' "$unit_path")
if [[ -n $unit_dir && $unit_dir != "$server_dir" ]]; then
	warn "$unit_path already runs a server in $unit_dir; continuing points it at $server_dir instead."
	confirm "Replace that unit?" n || die "cancelled"
fi

if ! $accept_eula && ! peek grep -qx 'eula=true' "$server_dir/eula.txt" &&
	confirm "Do you agree to the Minecraft EULA (https://aka.ms/MinecraftEULA)? The server won't start without it" n; then
	accept_eula=true
fi
confirm "Proceed with the install?" y || die "cancelled"

if [[ $service_mode == system ]]; then
	sudo -v
	sudo_ready=true
fi
if [[ $service_mode == system ]] && ! id -u "$SYSTEM_USER" >/dev/null 2>&1; then
	info "Creating system user $SYSTEM_USER"
	sudo useradd --system --user-group --home-dir "$server_dir" --no-create-home \
		--shell "$(command -v nologin || echo /bin/false)" "$SYSTEM_USER"
fi
[[ $service_mode != system ]] || system_group=$(id -gn "$SYSTEM_USER")

# Download and verify everything before stopping or replacing anything.
if [[ $previous_version == "$mc_version" && $previous_launcher == "$loader_version/$installer_version" ]] &&
	as_owner test -s "$server_dir/fabric-server-launch.jar" 2>/dev/null; then
	info "Fabric server launcher (loader $loader_version, installer $installer_version) already present"
else
	info "Fabric server launcher (loader $loader_version, installer $installer_version)"
	fetch -o "$tmp/fabric-server-launch.jar" \
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

ctl_in() {
	if [[ $1 == user ]]; then systemctl --user "${@:2}"; else sudo systemctl "${@:2}"; fi
}
service_ctl() { ctl_in "$service_mode" "$@"; }
state_in() {
	if [[ $1 == user ]]; then systemctl --user show -p ActiveState --value "$UNIT_NAME"; else systemctl show -p ActiveState --value "$UNIT_NAME"; fi
}
user_bus=false
systemctl --user show-environment >/dev/null 2>&1 && user_bus=true

serving_unit_active() {
	local scope file state
	for scope in user system; do
		file=$(unit_file_for "$scope")
		[[ -f $file && $(sed -n 's/^WorkingDirectory=//p' "$file") == "$server_dir" ]] || continue
		state=$(state_in "$scope" 2>/dev/null) || continue
		[[ -n $state && $state != inactive && $state != failed ]] && return 0
	done
	return 1
}
ports=("$java_port/tcp")
[[ $server_type == java ]] || ports+=("$bedrock_port/udp")
[[ $server_type == java ]] || ((signaling_port == 0)) || ports+=("$signaling_port/tcp")
if ! command -v ss >/dev/null; then
	warn "ss (iproute2) isn't installed, so a server started from start.sh can't be detected; make sure none is running"
elif ! serving_unit_active && [[ -n $(for p in "${ports[@]}"; do ss -Hln "--${p#*/}" "sport = :${p%/*}" 2>/dev/null; done) ]]; then
	warn "something is already listening on a selected server port (Java TCP $java_port, Bedrock UDP $bedrock_port, signaling TCP $signaling_port). If it's this server running from start.sh, stop it first: updating jars under a running server can break it."
	confirm "Continue anyway?" n || die "cancelled"
fi

was_running=false stopped_units=()
for scope in user system; do
	$have_systemd || break
	file=$(unit_file_for "$scope")
	[[ -f $file ]] || continue
	[[ $scope == "$service_mode" || $(sed -n 's/^WorkingDirectory=//p' "$file") == "$server_dir" ]] || continue
	[[ $scope == "$service_mode" || $scope == system ]] || $user_bus ||
		die "$file also serves $server_dir, but there's no user systemd session here to stop or remove it; rerun from a normal login"
	[[ $scope == user ]] || need_sudo "stop the system unit $file"
	state=$(state_in "$scope") || die "can't inspect the $scope unit $UNIT_NAME"
	[[ -n $state ]] || die "no state reported for the $scope unit $UNIT_NAME"
	if [[ $state != inactive && $state != failed ]]; then
		confirm "The $scope unit $UNIT_NAME is running. Stop it to update (players will be disconnected)?" y ||
			die "cancelled"
		stopped_units+=("$scope")
		was_running=true
	fi
	ctl_in "$scope" stop "$UNIT_NAME"
	state=$(state_in "$scope") || die "can't verify the $scope unit stopped"
	[[ $state == inactive || $state == failed ]] || die "the $scope unit is still $state; refusing to update"
	[[ $scope != "$service_mode" ]] || continue
	if ! confirm "Disable and remove the old $scope unit $file for this directory?" y; then
		warn "$file still points at $server_dir; never run it beside the new $service_mode unit"
		continue
	fi
	ctl_in "$scope" disable -q "$UNIT_NAME" || true
	if [[ $scope == user ]]; then rm -f "$file"; else sudo rm -f "$file"; fi
	ctl_in "$scope" daemon-reload
done

if [[ $service_mode == system ]]; then
	sudo install -d -o "$SYSTEM_USER" -g "$system_group" -m 750 "$server_dir"
else
	mkdir -p "$server_dir"
fi
[[ $service_mode != system || -z $dir_owner || $dir_owner == "$SYSTEM_USER" ]] ||
	sudo chown -R "$SYSTEM_USER:$system_group" "$server_dir"
as_owner mkdir -p "$server_dir/mods"

artifacts_pending=true
for rel in fabric-server-launch.jar "${mod_jars[@]/#/mods/}"; do
	[[ -f $tmp/$rel ]] || continue
	remember_artifact "$server_dir/$rel"
	place "$tmp/$rel" "$server_dir/$rel" 644
done
wanted_jars=$(printf '/%s' "${mod_jars[@]}")/
for old in "${previous_jars[@]}"; do
	[[ $wanted_jars != *"/$old/"* ]] || continue
	as_owner test -e "$server_dir/mods/$old" || continue
	remember_artifact "$server_dir/mods/$old"
	as_owner rm -f -- "$server_dir/mods/$old"
	info "Removed mods/$old (no longer part of this '$server_type' server)"
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
$([[ -z $previous_floodgate_locale ]] || echo "floodgate_locale=$previous_floodgate_locale")
EOF
artifacts_pending=false

if $accept_eula; then
	echo "eula=true" | write_file "$server_dir/eula.txt" 644
elif ! as_owner test -f "$server_dir/eula.txt"; then
	echo "eula=false" | write_file "$server_dir/eula.txt" 644
fi

if ! as_owner test -f "$server_dir/server.properties"; then
	motd="Fabric $mc_version"
	[[ $server_type == java ]] || motd+=" + Geyser"
	[[ $server_type != floodgate ]] || motd+=" + Floodgate"
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

geyser_config=$server_dir/config/Geyser-Fabric/config.yml
set_geyser_auth() {
	local found line current
	as_owner test -f "$geyser_config" || return 1
	found=$(as_owner cat -- "$geyser_config" | python3 -Ic "$YAML_WALK"'
for number, path, value in walk(sys.stdin):
    if value and path in ("java.auth-type", "remote.auth-type"):
        print(number, value.strip("\"\x27").lower())
        sys.exit()
print(0)') || die "couldn't read $geyser_config"
	read -r line current <<<"$found"
	((line)) || [[ -n ${2:-} ]] || die "couldn't find auth-type in $geyser_config (has its layout changed?); set it to $1 by hand"
	((line)) || return 0
	[[ $current != "$1" && (-z ${2:-} || $current == "$2") ]] || return 0
	as_owner sed -i -E "${line}s/^( *auth-type:).*/\1 $1/" "$geyser_config" ||
		die "couldn't set auth-type: $1 in $geyser_config; set it by hand"
}

floodgate_config=$server_dir/config/floodgate/config.yml
set_floodgate_locale() {
	local line
	[[ -z $previous_floodgate_locale ]] || return 0
	as_owner test -f "$floodgate_config" || return 1
	! as_owner grep -qE '^default-locale:' "$floodgate_config" || return 0
	as_owner grep -qF 'is not a supported Floodgate language' "$server_dir/logs/latest.log" 2>/dev/null || return 0
	line=$(as_owner grep -m1 -nxE '# *default-locale: *en_US *' "$floodgate_config") || return 0
	if ! echo "floodgate_locale=set" | as_owner tee -a -- "$server_dir/$STATE_FILE" >/dev/null; then
		warn "couldn't record a Floodgate locale change in $server_dir/$STATE_FILE, so left $floodgate_config alone"
		return 0
	fi
	if ! as_owner sed -i "${line%%:*}s/.*/default-locale: en_US/" "$floodgate_config"; then
		warn "couldn't set default-locale: en_US in $floodgate_config; uncomment it by hand to stop Floodgate's locale warning"
		return 0
	fi
	info "Floodgate's default-locale is now en_US (in $floodgate_config): it logged that it has no translation for the server's locale and was already using en_US"
}
needs_first_boot=false
[[ $server_type != geyser ]] || set_geyser_auth online floodgate || true
if [[ $server_type == floodgate ]] && ! set_geyser_auth floodgate; then
	needs_first_boot=true
elif [[ $server_type == floodgate ]] && ! set_floodgate_locale; then
	info "Floodgate writes its config on its first start; rerun this after that to check its locale"
fi

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

printf -v java_cmd '%q ' "$java_bin" "${java_args[@]}"
java_cmd=${java_cmd% }

{
	cat <<EOF
#!/usr/bin/env bash
# Generated by install.sh — edits are lost on rerun.
# Runs the server in this terminal with its console; type "stop" to quit.
set -euo pipefail
EOF
	[[ $service_mode != system ]] || cat <<EOF
if [[ \$(id -un) != $SYSTEM_USER ]]; then
	echo "run this as $SYSTEM_USER: sudo -u $SYSTEM_USER $(printf %q "$server_dir/start.sh" | sed 's/[\\"$`]/\\&/g')" >&2
	exit 1
fi
EOF
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
cd "\$(dirname "\$(readlink -f "\${BASH_SOURCE[0]}")")"
exec $java_cmd
EOF
} | write_file "$server_dir/start.sh" 755

ordering='' hardening='' wanted_by=default.target
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
	ordering="Wants=network-online.target
After=network-online.target"
fi
unit=$(
	cat <<EOF
[Unit]
Description=Minecraft $mc_version Fabric server ($server_type)
# RestartSec=10 spaces restarts out, so systemd's default limit (5 starts in
# 10 s) never trips and a crashing server restarts forever. With 5 starts in
# 10 minutes, the 6th start is refused when 5 x (uptime + 10 s) < 600 s, i.e.
# for a server that keeps dying within about 110 s of starting.
# Manual starts count too; systemctl reset-failed clears the count.
StartLimitIntervalSec=600
StartLimitBurst=5
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
elif [[ $service_mode == user ]]; then
	mkdir -p "$(dirname "$unit_path")"
	cat >"$unit_path" <<<"$unit"
	systemctl --user daemon-reload
fi

firewall_note='' fw=''
if systemctl is-active -q firewalld 2>/dev/null; then
	fw=firewalld
elif systemctl is-active -q ufw 2>/dev/null && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
	fw=ufw
fi
if [[ $fw == firewalld ]] && command -v sudo >/dev/null && confirm "firewalld is active. Open ${ports[*]} permanently in its default zone?" n; then
	for p in "${ports[@]}"; do sudo firewall-cmd -q --permanent --add-port="$p"; done
	sudo firewall-cmd -q --reload
	info "Opened ${ports[*]}; undo with: sudo firewall-cmd --permanent --remove-port=PORT/PROTO && sudo firewall-cmd --reload"
elif [[ $fw == firewalld ]]; then
	firewall_note="firewalld is active and this run didn't open ${ports[*]}; unless they're already open, other machines can't connect"
elif [[ $fw == ufw ]] && command -v sudo >/dev/null && confirm "ufw is active. Allow ${ports[*]}?" n; then
	for p in "${ports[@]}"; do sudo ufw allow "$p"; done
	info "Allowed ${ports[*]}; undo with: sudo ufw delete allow PORT/PROTO"
elif [[ $fw == ufw ]]; then
	firewall_note="ufw is active and this run didn't allow ${ports[*]}; unless they're already allowed, other machines can't connect"
elif ruleset=$(nft list ruleset 2>/dev/null || { $sudo_ready && sudo -n nft list ruleset 2>/dev/null; }); then
	! grep -Eq 'hook input .*policy drop' <<<"$ruleset" ||
		firewall_note="an nftables input chain drops unmatched traffic; unless it allows ${ports[*]}, other machines can't connect"
else
	for fw_unit in nftables iptables; do
		systemctl is-active -q "$fw_unit" 2>/dev/null || continue
		firewall_note="$fw_unit.service is active and its ruleset can't be read without root; make sure it allows ${ports[*]}, or other machines can't connect"
		break
	done
fi

alive() {
	local stat
	stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
	[[ ${stat##*) } != Z* ]]
}
boot_pidfile='' boot_java_pid=''
shut_down_boot() {
	local wait_until=$((SECONDS + 120)) java_pid=${boot_java_pid:-}
	[[ -n $boot_pid ]] || return 0
	[[ -n $java_pid ]] || java_pid=$(as_owner cat "$boot_pidfile" 2>/dev/null || true)
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
	fi
	if boot_alive; then
		boot_stop_failed=true
		warn "couldn't stop the first-boot server (PID ${java_pid:-$boot_pid}); stop it by hand before starting another"
		return 1
	fi
	as_owner rm -f "$boot_pidfile"
	wait "$boot_pid" 2>/dev/null || true
	boot_pid=''
}
first_boot() {
	local log=$tmp/first-boot.log deadline=$((SECONDS + 600)) why=''
	boot_pidfile=$server_dir/.first-boot.pid
	: >"$log"
	info "First boot: generating the world and configs (can take a few minutes)"
	as_owner rm -f "$boot_pidfile"
	# shellcheck disable=SC2016
	local wrapper=(bash -c 'cd "$1" && echo $$ >"$2" && shift 2 && exec "$@"'
		_ "$server_dir" "$boot_pidfile" "$java_bin" "${java_args[@]}")
	# Not through as_owner: $! must be the wrapper (or its sudo) itself, which records the JVM's PID.
	if [[ $service_mode == system ]]; then
		(cd / && exec sudo -u "$SYSTEM_USER" "${wrapper[@]}") </dev/null >"$log" 2>&1 &
	else
		"${wrapper[@]}" </dev/null >"$log" 2>&1 &
	fi
	boot_pid=$!
	boot_java_pid=''
	for _ in {1..20}; do
		boot_java_pid=$(as_owner cat "$boot_pidfile" 2>/dev/null || true)
		[[ -z $boot_java_pid ]] || break
		sleep 0.5
	done
	until grep -qE 'Done \([0-9.]+s\)!' "$log"; do
		[[ $service_mode != system ]] || sudo -n -v 2>/dev/null || true
		((SECONDS <= deadline)) || why="first boot didn't finish within 10 minutes (log above)"
		alive "$boot_pid" || why="the server exited during its first boot (log above)"
		[[ -z $why ]] || break
		sleep 2
	done
	shut_down_boot
	[[ -z $why ]] || tail -n 20 "$log" >&2
	[[ -z $why ]] || die "$why"
}

if $needs_first_boot && ! as_owner grep -qx 'eula=true' "$server_dir/eula.txt"; then
	warn "Floodgate setup is unfinished: accept the EULA, start the server once, stop it, then rerun this script."
elif $needs_first_boot && confirm "Boot the server once now to finish Floodgate setup?" y; then
	[[ $service_mode != system ]] || sudo -v
	first_boot
	set_geyser_auth floodgate || die "Geyser didn't write $geyser_config on first boot"
	info "Geyser now uses Floodgate auth"
	set_floodgate_locale || warn "Floodgate didn't write $floodgate_config on first boot, so its locale wasn't checked"
elif $needs_first_boot; then
	warn "Floodgate setup is unfinished: start the server once, stop it, then rerun this script."
fi

readonly START_WATCH=15
stays_up() {
	local i state
	info "Checking that the server stays up for $START_WATCH s"
	for ((i = 0; i < START_WATCH; i++)); do
		sleep 1
		state=$(state_in "$service_mode") || return 1
		[[ $state == active ]] || return 1
	done
}

start_failed=false can_start=false enabled=n user_flag=()
autostart_q="Start the server automatically at boot?"
if [[ $service_mode == user ]]; then
	user_flag=(--user)
	autostart_q="Start the server automatically at boot (enables the unit and lingering for $me)?"
fi
[[ $service_mode != none ]] && as_owner grep -qx 'eula=true' "$server_dir/eula.txt" && can_start=true
$can_start && systemctl "${user_flag[@]}" is-enabled -q "$UNIT_NAME" 2>/dev/null && enabled=y
if $can_start && confirm "$autostart_q" "$enabled"; then
	service_ctl enable -q "$UNIT_NAME"
	[[ $service_mode != user ]] || loginctl enable-linger "$me" ||
		warn "couldn't enable lingering, so the server only runs while you're logged in; run: loginctl enable-linger $me"
elif [[ $enabled == y ]]; then
	service_ctl disable -q "$UNIT_NAME"
fi
if $can_start && confirm "Start the server now?" "$($was_running && echo y || echo n)"; then
	service_ctl start "$UNIT_NAME"
	stays_up || start_failed=true
fi

if [[ $service_mode == none ]] && $was_running; then
	warn "the server's old unit was stopped for this update; start it again with start.sh"
fi

finished=true

addresses=$(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | paste -sd' ' || true)
if $start_failed; then heading="Installed, but not running"; else heading=Done; fi
cat <<EOF

$heading: Minecraft $mc_version Fabric server in $server_dir
  Java players:    ${addresses:-<this host>} port $java_port
EOF
[[ $server_type == java ]] || echo "  Bedrock gameplay: ${addresses:-<this host>} UDP $bedrock_port"
if [[ $server_type != java ]] && ((signaling_port)); then
	echo "  Bedrock signaling: ${addresses:-<this host>} TCP $signaling_port"
elif [[ $server_type != java ]]; then
	echo "  Bedrock signaling: external NXS service (no separate TCP listener)"
fi
[[ -z $firewall_note ]] || echo "  Firewall:        warning: $firewall_note"
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
! $start_failed || die "$UNIT_NAME stopped within $START_WATCH s of starting; see its log with the journalctl command above"
