#!/bin/sh
# minecraft-twingate.sh
# A private Minecraft Java server behind a Twingate Connector with Docker Compose, no published
# ports; installs Docker first on the Arch, Fedora/EL and Debian/Ubuntu families. POSIX sh.
# Docs: docs/minecraft-twingate.md

set -eu
umask 022

MC_DIR=${MC_DIR:-/opt/minecraft-server}
TG_NETWORK=${TG_NETWORK:-}
TG_URL=""
TG_ACCESS_TOKEN=${TG_ACCESS_TOKEN:-}
TG_REFRESH_TOKEN=${TG_REFRESH_TOKEN:-}
MC_MEMORY=${MC_MEMORY:-}
MC_TYPE=${MC_TYPE:-}
MC_VERSION=${MC_VERSION:-}
MC_SUBNET=${MC_SUBNET:-}
MC_DIFFICULTY=${MC_DIFFICULTY:-}
MC_MAX_PLAYERS=${MC_MAX_PLAYERS:-}
MC_MOTD=${MC_MOTD:-}
MC_OPS=${MC_OPS-__unset__}
MC_SEED=${MC_SEED-__unset__}
MC_EULA=${MC_EULA:-}
MC_IMAGE_TAG=${MC_IMAGE_TAG:-}
MC_WAIT=${MC_WAIT:-600}
# Fixed so the route that pin_route adds (and its systemd unit) can name the bridge.
# compose.yaml in write_config repeats it literally: change both together.
MC_BRIDGE=mc-twingate0
NET_NAME=minecraft-twingate_minecraft-net
ROUTE_UNIT=/etc/systemd/system/minecraft-twingate-route.service
OS_RELEASE=${OS_RELEASE:-/etc/os-release}
DEBIAN_VERSION_FILE=${DEBIAN_VERSION_FILE:-/etc/debian_version}
CODENAME="" REPLACE=0 DRY_RUN=0 INSTALL_ONLY="" TMP="" REPO_BAK="" REPO_PENDING="" FAMILY="" REPO="" SUITE="" CONFLICTS=""
NL='
'

log() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() {
	printf '[x] %s\n' "$*" >&2
	exit 1
}
cleanup() {
	[ -z "$TMP" ] || rm -f "$TMP"
	# An interrupted or failed repo setup puts the old repo file back (see repo_backup).
	[ -z "$REPO_PENDING" ] || repo_restore "$REPO_PENDING"
	[ ! -t 0 ] || stty echo 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
	cat <<'EOF'
Usage (as root): minecraft-twingate.sh COMMAND [options]
  install    install Docker if needed, write config, start, wait until ready
  update     re-apply .env and flags, pull newer images, recreate
  status     containers, readiness, Connector state, Resource address

Options (or the environment variable on the right; these settings are saved to .env):
  --dir /opt/minecraft-server   stack folder, pass it to every command    MC_DIR
  --network NAME                Twingate tenant: NAME, or the full address TG_NETWORK
                                such as NAME.us2.twingate.com
  --memory 2G                   Java heap                                  MC_MEMORY
  --type VANILLA                VANILLA, PAPER, FORGE, FABRIC...           MC_TYPE
  --version LATEST              Minecraft version, such as 1.21.1          MC_VERSION
  --subnet 172.30.0.0/24        private bridge /24; the server gets .10    MC_SUBNET
  --accept-eula                 accept Mojang's EULA (https://aka.ms/MinecraftEULA)

install only, not saved:
  --codename trixie             Docker apt suite for an unmapped Debian derivative
  --replace-conflicts           remove distro packages that clash with Docker's
  --dry-run                     print package steps and write the config to a temp
                                folder, tokens redacted; no root needed (except to
                                read a root-owned live .env)

Environment only, saved: TG_ACCESS_TOKEN and TG_REFRESH_TOKEN (else prompted; never
flags), MC_DIFFICULTY, MC_MAX_PLAYERS, MC_MOTD, MC_OPS, MC_SEED, MC_IMAGE_TAG (itzg
image tag, such as java8 for old Forge). Not saved: MC_WAIT (seconds to wait, default 600).
Docs: docs/minecraft-twingate.md
EOF
}

# run CMD...: runs it, or under --dry-run only prints it.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '+ %s\n' "$*"
		return 0
	fi
	"$@"
}

# matches ERE VALUE: VALUE is one line and matches ^(ERE)$.
matches() {
	case "$2" in *"$NL"*) return 1 ;; esac
	printf '%s\n' "$2" | grep -Eq "^($1)\$"
}

# write_file PATH MODE < content: atomic replace via a temp file in the same folder.
write_file() {
	TMP=$(mktemp "$1.XXXXXX")
	cat >"$TMP"
	chmod "$2" "$TMP"
	mv -f "$TMP" "$1"
	TMP=""
	log "Wrote $1"
}

# env_get KEY: the last saved value of KEY in .env, without trailing blanks or one pair of
# surrounding single or double quotes, so a hand-edited KEY="value" reads as Compose reads it.
# Only one layer comes off: after a single-quote strip, t skips the double-quote one, so a saved
# MC_MOTD='"Hi"' keeps its double quotes.
env_get() {
	[ -f "$ENV_FILE" ] || return 0
	[ -r "$ENV_FILE" ] || die "Cannot read $ENV_FILE. Run as root."
	# The blank strip needs its own sed: it always counts as a substitution, which would trip t.
	sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed 's/[[:space:]]*$//' |
		sed -e "s/^'\\(.*\\)'\$/\\1/" -e t -e 's/^"\(.*\)"$/\1/'
}

# pick CURRENT KEY DEFAULT: flag or environment value, then the saved .env, then the default.
pick() {
	if [ -n "$1" ]; then
		printf '%s' "$1"
		return 0
	fi
	pick_saved=$(env_get "$2")
	printf '%s' "${pick_saved:-$3}"
}

# pick_empty works like pick for settings where empty is a real value (MC_OPS, MC_SEED).
pick_empty() {
	if [ "$1" != __unset__ ]; then
		printf '%s' "$1"
		return 0
	fi
	env_get "$2"
}

ask_secret() {
	[ -t 0 ] || die "$1 is not set. Export it, or run from a terminal to be prompted."
	printf '%s: ' "$1" >&2
	stty -echo
	IFS= read -r ask_value || ask_value=""
	stty echo
	printf '\n' >&2
	printf '%s' "$ask_value"
}

# ---------- distro detection ----------

detect_os() {
	[ -r "$OS_RELEASE" ] || die "Cannot read $OS_RELEASE to identify the distribution."
	ID="" ID_LIKE="" VERSION_ID="" VERSION_CODENAME="" UBUNTU_CODENAME="" DEBIAN_CODENAME="" PLATFORM_ID="" PRETTY_NAME=""
	# shellcheck disable=SC1090
	. "$OS_RELEASE"
	case " $ID $ID_LIKE " in
	*" arch "* | *" archarm "*) FAMILY=arch ;;
	*" ubuntu "*) detect_ubuntu ;;
	*" debian "* | *" raspbian "*) detect_debian ;;
	*" fedora "* | *" rhel "* | *" centos "*) detect_rpm ;;
	*) die "Docker can't be installed here: supported are the Arch, Fedora/EL and Debian/Ubuntu families. Found: ${PRETTY_NAME:-$ID}" ;;
	esac
	[ -z "$CODENAME" ] || [ "$FAMILY" = debian ] || die "--codename applies to Debian and Ubuntu only."
	log "Distribution: ${PRETTY_NAME:-$ID} -> $FAMILY${REPO:+ ($REPO${SUITE:+ $SUITE})}"
}

# Ubuntu and its derivatives (Mint, Pop!_OS, Zorin...) use Docker's Ubuntu repo and suite.
detect_ubuntu() {
	FAMILY=debian REPO=ubuntu
	SUITE=${CODENAME:-${UBUNTU_CODENAME:-$VERSION_CODENAME}}
	[ -n "$SUITE" ] || die "No Ubuntu codename in $OS_RELEASE. Pass --codename, such as noble."
}

# Debian derivatives often set their own VERSION_CODENAME, so map them to a Debian release.
detect_debian() {
	FAMILY=debian REPO=debian
	# 32-bit Raspberry Pi OS uses Debian's armhf (ARMv7) packages, as Docker now advises; its own
	# raspbian repo got no new major after v28, and ARMv6 boards have no official packages at all.
	[ "$ID" != raspbian ] || case "$(uname -m)" in
	armv6*) die "ARMv6 boards (Raspberry Pi 1, Zero, Zero W) have no official Docker packages." ;;
	esac
	SUITE=$CODENAME
	[ -n "$SUITE" ] || SUITE=$DEBIAN_CODENAME
	# Debian stable sets VERSION_ID; testing and unstable don't, and Docker has no suite for them.
	if [ -z "$SUITE" ] && [ "$ID" = debian ]; then
		[ -n "$VERSION_ID" ] ||
			die "Debian testing/unstable ('$VERSION_CODENAME') has no Docker suite. Pass --codename trixie to use the stable one."
		SUITE=$VERSION_CODENAME
	fi
	if [ -z "$SUITE" ] && [ -r "$DEBIAN_VERSION_FILE" ]; then
		case "$(cat "$DEBIAN_VERSION_FILE")" in
		12 | 12.*) SUITE=bookworm ;;
		13 | 13.*) SUITE=trixie ;;
		14 | 14.*) SUITE=forky ;;
		esac
	fi
	[ -n "$SUITE" ] || die "Cannot map ${PRETTY_NAME:-$ID} to a Debian release. Pass --codename, such as trixie."
}

# Fedora-based and EL-based systems both list fedora (and Nobara even rhel) in ID_LIKE, so tell
# them apart by PLATFORM_ID (platform:f43, platform:el10). Fedora 45 dropped PLATFORM_ID; then
# the VERSION_ID major decides: 8-10 is EL, two digits is Fedora.
detect_rpm() {
	FAMILY=rpm
	# dnf can't install onto an image-based system, so stop before any repo is written.
	[ ! -e /run/ostree-booted ] ||
		die "This is an rpm-ostree system (Silverblue, Kinoite, CoreOS...). Layer Docker with rpm-ostree, or use a host where dnf installs packages."
	rpm_base=""
	case "$PLATFORM_ID" in
	platform:el8 | platform:el9 | platform:el10) rpm_base=el ;;
	platform:f[0-9]*) rpm_base=fedora ;;
	"")
		case "${VERSION_ID:-}" in
		8 | 8.* | 9 | 9.* | 10 | 10.*) rpm_base=el ;;
		[1-9][0-9] | [1-9][0-9].*) rpm_base=fedora ;;
		esac
		;;
	esac
	case "$rpm_base" in
	fedora)
		REPO=fedora
		# Docker's list, plus Fedora's own Docker packages, which it doesn't name but which
		# conflict with docker-ce, docker-ce-cli and the two plugins.
		CONFLICTS="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine moby-engine docker-cli docker-compose docker-buildx podman-docker"
		;;
	el)
		REPO=centos
		CONFLICTS="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker"
		[ "$ID" != rhel ] || {
			REPO=rhel
			CONFLICTS="$CONFLICTS podman runc"
		}
		;;
	*) die "${PRETTY_NAME:-$ID} is not Fedora or EL 8-10, the RPM systems Docker publishes packages for." ;;
	esac
}

# ---------- Docker install ----------

# installed_conflicts: prints the distro packages that clash with Docker's own.
installed_conflicts() {
	for pkg in $CONFLICTS; do
		case "$FAMILY" in
		arch) pacman -Q "$pkg" >/dev/null 2>&1 && printf '%s ' "$pkg" ;;
		debian) dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q ' installed$' && printf '%s ' "$pkg" ;;
		rpm) rpm -q "$pkg" >/dev/null 2>&1 && printf '%s ' "$pkg" ;;
		esac
	done
	return 0
}

remove_conflicts() {
	found=$(installed_conflicts)
	[ -n "$found" ] || return 0
	[ "$REPLACE" = 1 ] || [ "$DRY_RUN" = 1 ] || die "These packages conflict with Docker's: $found
Remove them yourself, or re-run with --replace-conflicts to have this script remove them."
	[ "$REPLACE" = 1 ] || {
		warn "A real install would stop here: $found conflict with Docker's packages (see --replace-conflicts)."
		return 0
	}
	warn "Removing conflicting packages: $found"
	# shellcheck disable=SC2086 # $found is a space-separated package list
	case "$FAMILY" in
	arch) run pacman -R --noconfirm $found ;;
	debian) run apt-get remove -y $found ;;
	rpm) run dnf remove -y $found ;;
	esac
}

# Each installer downloads Docker's packages before it removes any conflicting package, so a
# failed download never leaves the host without its old container engine.
install_docker_arch() {
	# -S without -y: refreshing the databases without upgrading would be a partial upgrade.
	run pacman -Sw --needed --noconfirm docker docker-compose ||
		die "pacman could not download Docker. If it got 404s, run 'pacman -Syu' (and reboot after a kernel upgrade), then re-run."
	# --noconfirm answers pacman's "remove conflicting podman-docker?" with no, so ask first.
	CONFLICTS="podman-docker"
	remove_conflicts
	run pacman -S --needed --noconfirm docker docker-compose
}

# repo_backup FILE saves a copy of an existing repo file before it is rewritten; repo_restore FILE
# puts that copy back (or removes a file this run created); repo_keep drops the copy once the new
# file has proved itself. The copy lives in /tmp, not the repo folder, so apt or dnf never reads it.
repo_backup() {
	REPO_BAK=""
	[ "$DRY_RUN" = 0 ] || return 0
	REPO_PENDING=$1
	[ -f "$1" ] || return 0
	REPO_BAK=$(mktemp)
	cp -p "$1" "$REPO_BAK"
}
repo_restore() {
	[ "$DRY_RUN" = 0 ] || return 0
	if [ -n "$REPO_BAK" ]; then
		mv -f "$REPO_BAK" "$1"
	else
		rm -f "$1"
	fi
	REPO_BAK="" REPO_PENDING=""
}
repo_keep() {
	[ -z "$REPO_BAK" ] || rm -f "$REPO_BAK"
	REPO_BAK="" REPO_PENDING=""
}

install_docker_debian() {
	# An older Docker repo entry with another Signed-By key path next to docker.sources makes
	# apt fail outright ("Conflicting values set for option Signed-By"). One that uses the same
	# docker.asc only draws a warning. Check before removing anything, so a stop here never
	# leaves the host without its old Docker.
	others=""
	for src in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
		[ -f "$src" ] && [ "$src" != /etc/apt/sources.list.d/docker.sources ] || continue
		grep -qE '^[[:space:]]*[^#[:space:]].*download\.docker\.com' "$src" || continue
		grep -q '/etc/apt/keyrings/docker\.asc' "$src" || others="$others $src"
	done
	[ -z "$others" ] || die "Docker's apt repo is already set up with another signing key in:$others
Remove or rename those files (apt reads only *.list and *.sources), then re-run."
	# A snap Docker has no dockerd on PATH, so it would look missing and get a second engine beside it.
	! command -v snap >/dev/null 2>&1 || ! snap list docker >/dev/null 2>&1 ||
		die "Docker is installed as a snap. Use it as is, or remove it (snap remove docker) and re-run."
	export DEBIAN_FRONTEND=noninteractive
	run apt-get update
	run apt-get install -y ca-certificates curl
	run install -m 0755 -d /etc/apt/keyrings
	run curl -fsSL "https://download.docker.com/linux/$REPO/gpg" -o /etc/apt/keyrings/docker.asc
	run chmod a+r /etc/apt/keyrings/docker.asc
	arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
	repo_backup /etc/apt/sources.list.d/docker.sources
	if [ "$DRY_RUN" = 1 ]; then
		printf '+ write /etc/apt/sources.list.d/docker.sources (Suites: %s, Architectures: %s)\n' "$SUITE" "$arch"
	else
		write_file /etc/apt/sources.list.d/docker.sources 644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/$REPO
Suites: $SUITE
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
	fi
	# A repo that doesn't serve this suite would break every later apt run, so put back what was there.
	run apt-get update || {
		repo_restore /etc/apt/sources.list.d/docker.sources
		die "apt-get update failed once Docker's repo was set up (see its output above), so docker.sources was put back as it was. Either Docker has no '$SUITE' suite for $REPO (check --codename, or that Docker supports this release) or a download failed; re-run to retry."
	}
	repo_keep
	run apt-get install -y --download-only docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
		die "Could not download Docker's packages; nothing was removed or installed."
	CONFLICTS="docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc"
	remove_conflicts
	run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rpm() {
	command -v curl >/dev/null 2>&1 || run dnf install -y curl
	# Fetching the .repo file directly works the same under dnf4 (EL) and dnf5 (Fedora 41+),
	# whose config-manager syntaxes differ. makecache proves the repo serves this release.
	repo_backup /etc/yum.repos.d/docker-ce.repo
	run curl -fsSL "https://download.docker.com/linux/$REPO/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo || {
		repo_restore /etc/yum.repos.d/docker-ce.repo
		die "Could not download Docker's $REPO .repo file."
	}
	run dnf -q makecache --repo docker-ce-stable || {
		repo_restore /etc/yum.repos.d/docker-ce.repo
		die "dnf could not load Docker's $REPO repo (see above), so docker-ce.repo was put back as it was. Either Docker doesn't serve this release or a download failed; re-run to retry."
	}
	repo_keep
	# --allowerasing only lets the resolver plan around the conflicts; --downloadonly removes nothing.
	run dnf install -y --downloadonly --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
		die "Could not download Docker's packages; nothing was removed or installed."
	remove_conflicts
	run dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker() {
	# podman-docker turns /run/docker.sock into a link to Podman's socket and leaves the link behind
	# when it's removed, so a running dockerd would be unreachable until restarted. Only a link into
	# Podman's socket folder is touched; any other link was set up on purpose.
	relink=0
	sock_target=""
	[ ! -L /run/docker.sock ] || sock_target=$(readlink /run/docker.sock)
	case "$sock_target" in
	*/podman/*)
		warn "Removing /run/docker.sock, a leftover link to $sock_target, and restarting Docker"
		run rm -f /run/docker.sock
		relink=1
		;;
	esac
	if [ -d /run/systemd/system ]; then
		# dockerd on PATH without a system unit means rootless Docker or Docker Desktop.
		systemctl cat docker.service >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ] ||
			die "Docker has no system docker.service here (rootless Docker or Docker Desktop?). This script needs the system Docker Engine."
		run systemctl enable --now docker
		[ "$relink" = 0 ] || {
			run systemctl restart docker.socket 2>/dev/null || true
			run systemctl restart docker
		}
	elif command -v rc-service >/dev/null 2>&1; then
		[ -e /etc/init.d/docker ] || [ "$DRY_RUN" = 1 ] ||
			die "Docker has no OpenRC service here. On Artix, install docker-openrc, then re-run."
		# Init scripts return non-zero when Docker already runs; the docker info wait decides.
		run rc-update add docker default || true
		run rc-service docker start || true
		[ "$relink" = 0 ] || run rc-service docker restart
	elif command -v service >/dev/null 2>&1; then
		run service docker start || true
		[ "$relink" = 0 ] || run service docker restart
	else
		warn "No systemd, OpenRC or service command: start the Docker daemon yourself."
	fi
}

# dockerd marks a real Docker Engine: podman-docker's docker shim answers 'compose version' too.
docker_present() { command -v dockerd >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

# The distribution only matters for installing packages (main runs detect_os only then), so a
# host that already has a working Docker runs on any distribution.
ensure_docker() {
	if docker_present; then
		log "Docker and the Compose plugin are already installed; leaving packages alone."
	else
		log "Installing Docker Engine and the Compose plugin ($FAMILY)"
		"install_docker_$FAMILY"
	fi
	docker_up
}

# docker_up: start the daemon and wait until it answers. update runs it too, so check_ownership
# never mistakes a stopped daemon for missing containers.
docker_up() {
	start_docker
	[ "$DRY_RUN" = 1 ] && return 0
	# Non-systemd init scripts can return before dockerd has created its socket.
	waited=0
	until docker info >/dev/null 2>&1; do
		[ "$waited" -lt 30 ] || die "The Docker daemon is not answering after 30s. Check its service status and logs."
		sleep 2
		waited=$((waited + 2))
	done
	docker compose version >/dev/null 2>&1 || die "'docker compose' does not work. Install Docker's Compose plugin."
}

# ---------- config ----------

resolve_config() {
	TG_NETWORK=$(pick "$TG_NETWORK" TG_NETWORK "")
	TG_ACCESS_TOKEN=$(pick "$TG_ACCESS_TOKEN" TG_ACCESS_TOKEN "")
	TG_REFRESH_TOKEN=$(pick "$TG_REFRESH_TOKEN" TG_REFRESH_TOKEN "")
	MC_MEMORY=$(pick "$MC_MEMORY" MC_MEMORY 2G)
	MC_TYPE=$(pick "$MC_TYPE" MC_TYPE VANILLA)
	MC_VERSION=$(pick "$MC_VERSION" MC_VERSION LATEST)
	MC_SUBNET=$(pick "$MC_SUBNET" MC_SUBNET 172.30.0.0/24)
	MC_DIFFICULTY=$(pick "$MC_DIFFICULTY" MC_DIFFICULTY normal)
	MC_MAX_PLAYERS=$(pick "$MC_MAX_PLAYERS" MC_MAX_PLAYERS 10)
	MC_MOTD=$(pick "$MC_MOTD" MC_MOTD "Private Minecraft Server")
	MC_OPS=$(pick_empty "$MC_OPS" MC_OPS)
	MC_SEED=$(pick_empty "$MC_SEED" MC_SEED)
	MC_IMAGE_TAG=$(pick "$MC_IMAGE_TAG" MC_IMAGE_TAG latest)
	MC_EULA=$(pick "$MC_EULA" MC_EULA "")
	case "$MC_EULA" in [Tt][Rr][Uu][Ee]) MC_EULA=TRUE ;; esac
	# itzg reads latest and snapshot in any case; normalise so the LATEST world warning sees it.
	case "$MC_VERSION" in [Ll][Aa][Tt][Ee][Ss][Tt]) MC_VERSION=LATEST ;; [Ss][Nn][Aa][Pp][Ss][Hh][Oo][Tt]) MC_VERSION=SNAPSHOT ;; esac

	if [ "$MC_EULA" != TRUE ] && [ -t 0 ]; then
		printf "Accept Mojang's Minecraft EULA (https://aka.ms/MinecraftEULA)? [y/N] " >&2
		IFS= read -r answer || answer=""
		case "$answer" in [yY] | [yY][eE][sS]) MC_EULA=TRUE ;; esac
	fi
	[ "$MC_EULA" = TRUE ] || die "The server needs Mojang's EULA accepted: re-run with --accept-eula."
	[ -n "$TG_NETWORK" ] || [ ! -t 0 ] || {
		printf 'Twingate tenant (the NAME in NAME.twingate.com): ' >&2
		IFS= read -r TG_NETWORK || TG_NETWORK=""
	}
	# A preview redacts the tokens anyway, so it doesn't need real ones.
	[ "$DRY_RUN" = 0 ] || TG_ACCESS_TOKEN=${TG_ACCESS_TOKEN:-REDACTED-PREVIEW-ONLY} TG_REFRESH_TOKEN=${TG_REFRESH_TOKEN:-REDACTED-PREVIEW-ONLY}
	[ -n "$TG_ACCESS_TOKEN" ] || TG_ACCESS_TOKEN=$(ask_secret TG_ACCESS_TOKEN)
	[ -n "$TG_REFRESH_TOKEN" ] || TG_REFRESH_TOKEN=$(ask_secret TG_REFRESH_TOKEN)

	octet='25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9]'
	[ -n "$TG_NETWORK" ] || die "TG_NETWORK is not set. Pass --network NAME (from NAME.twingate.com) or export it."
	# The full address also works, and is needed for regional tenants (NAME.us2.twingate.com):
	# the Connector gets TWINGATE_URL, as Twingate's own Helm chart sets it.
	TG_NETWORK=${TG_NETWORK#https://}
	TG_NETWORK=${TG_NETWORK%%/*}
	case "$TG_NETWORK" in *.*) ;; *) TG_NETWORK=$TG_NETWORK.twingate.com ;; esac
	matches '[A-Za-z0-9][A-Za-z0-9-]{0,62}\.([a-z0-9-]+\.)*twingate\.com' "$TG_NETWORK" ||
		die "Invalid Twingate tenant '$TG_NETWORK': use NAME or its address, such as NAME.us2.twingate.com"
	TG_URL=https://$TG_NETWORK
	matches '[A-Za-z0-9._~+/=-]{16,}' "$TG_ACCESS_TOKEN" || die "TG_ACCESS_TOKEN looks wrong: copy it again from the Admin Console."
	matches '[A-Za-z0-9._~+/=-]{16,}' "$TG_REFRESH_TOKEN" || die "TG_REFRESH_TOKEN looks wrong: copy it again from the Admin Console."
	matches '[1-9][0-9]{0,5}[MG]' "$MC_MEMORY" || die "Invalid --memory '$MC_MEMORY': use a size such as 2G or 1536M."
	matches '[A-Z][A-Z_]*' "$MC_TYPE" || die "Invalid --type '$MC_TYPE': use VANILLA, PAPER, FORGE, FABRIC or another itzg TYPE."
	matches '[A-Za-z0-9][A-Za-z0-9._-]*' "$MC_VERSION" || die "Invalid --version '$MC_VERSION'"
	# Private (RFC 1918) ranges only: a public or loopback /24 would shadow real routes on the host.
	matches "10\\.($octet)\\.($octet)\\.0/24|172\\.(1[6-9]|2[0-9]|3[01])\\.($octet)\\.0/24|192\\.168\\.($octet)\\.0/24" "$MC_SUBNET" ||
		die "Invalid --subnet '$MC_SUBNET': use a private /24 (10.x, 172.16-31.x, 192.168.x) such as 172.30.0.0/24."
	matches 'peaceful|easy|normal|hard' "$MC_DIFFICULTY" || die "Invalid MC_DIFFICULTY '$MC_DIFFICULTY'"
	matches '[1-9][0-9]{0,3}' "$MC_MAX_PLAYERS" || die "Invalid MC_MAX_PLAYERS '$MC_MAX_PLAYERS'"
	# Compose reads \' as an escaped quote even inside single quotes, so backslashes are out too.
	matches "[^'\$\\]{1,120}" "$MC_MOTD" || die "MC_MOTD must be 1-120 characters without ', \$ or \\."
	matches '([A-Za-z0-9_]{3,16}(,[A-Za-z0-9_]{3,16})*)?' "$MC_OPS" || die "MC_OPS must be comma-separated Minecraft usernames."
	matches "[^'\$\\]{0,64}" "$MC_SEED" || die "MC_SEED must be up to 64 characters without ', \$ or \\."
	matches '[A-Za-z0-9][A-Za-z0-9._-]{0,127}' "$MC_IMAGE_TAG" || die "Invalid MC_IMAGE_TAG '$MC_IMAGE_TAG': use an itzg tag such as latest or java8."
	MC_SERVER_IP=${MC_SUBNET%.0/24}.10
	# Dynamic addresses (the Connector's) come only from the top half, so .10 is never handed out.
	MC_IP_RANGE=${MC_SUBNET%.0/24}.128/25
}

check_memory() {
	[ -r /proc/meminfo ] || return 0
	total_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || true)
	[ -n "$total_mb" ] || return 0
	heap_mb=${MC_MEMORY%?}
	case "$MC_MEMORY" in *G) heap_mb=$((heap_mb * 1024)) ;; esac
	[ "$total_mb" -ge $((heap_mb + 768)) ] ||
		warn "Host has ${total_mb} MB RAM; a ${MC_MEMORY} heap plus Java and the Connector may not fit."
}

write_config() {
	mkdir -p "${ENV_FILE%/.env}/data"
	# Values are single-quoted, which Compose reads literally; validation bans ' in all of them.
	write_file "$ENV_FILE" 600 <<EOF
# Generated by minecraft-twingate.sh. Keep this file private: it holds the Connector tokens.
# Edit a value, then run: minecraft-twingate.sh update --dir $MC_DIR
# Keep the KEY='value' form: no export, no spaces around =, no comment after a value.
TG_NETWORK='$TG_NETWORK'
TG_URL='$TG_URL'
TG_ACCESS_TOKEN='$TG_ACCESS_TOKEN'
TG_REFRESH_TOKEN='$TG_REFRESH_TOKEN'
MC_EULA='$MC_EULA'
MC_MEMORY='$MC_MEMORY'
MC_TYPE='$MC_TYPE'
MC_VERSION='$MC_VERSION'
MC_DIFFICULTY='$MC_DIFFICULTY'
MC_MAX_PLAYERS='$MC_MAX_PLAYERS'
MC_MOTD='$MC_MOTD'
MC_OPS='$MC_OPS'
MC_SEED='$MC_SEED'
MC_SUBNET='$MC_SUBNET'
MC_SERVER_IP='$MC_SERVER_IP'
MC_IP_RANGE='$MC_IP_RANGE'
MC_IMAGE_TAG='$MC_IMAGE_TAG'
EOF
	write_file "$COMPOSE_FILE" 644 <<'EOF'
# Generated by minecraft-twingate.sh. Settings live in .env; edit it and run update.
# No ports are published: players reach the server only through the Twingate Connector.
name: minecraft-twingate

x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  minecraft:
    image: "itzg/minecraft-server:${MC_IMAGE_TAG}"
    container_name: minecraft-server
    environment:
      EULA: "${MC_EULA}"
      MEMORY: "${MC_MEMORY}"
      TYPE: "${MC_TYPE}"
      VERSION: "${MC_VERSION}"
      DIFFICULTY: "${MC_DIFFICULTY}"
      MAX_PLAYERS: "${MC_MAX_PLAYERS}"
      MOTD: "${MC_MOTD}"
      OPS: "${MC_OPS}"
      SEED: "${MC_SEED}"
    volumes:
      - ./data:/data:Z
    networks:
      minecraft-net:
        ipv4_address: "${MC_SERVER_IP}"
    restart: unless-stopped
    # The image waits up to 60s for the final world save; Docker's default 10s would cut it off.
    stop_grace_period: 75s
    logging: *logging

  twingate-connector:
    image: twingate/connector:1
    container_name: twingate-connector
    environment:
      TWINGATE_URL: "${TG_URL}"
      TWINGATE_ACCESS_TOKEN: "${TG_ACCESS_TOKEN}"
      TWINGATE_REFRESH_TOKEN: "${TG_REFRESH_TOKEN}"
    sysctls:
      net.ipv4.ping_group_range: "0 2147483647"
    networks:
      - minecraft-net
    restart: unless-stopped
    logging: *logging

networks:
  minecraft-net:
    driver_opts:
      # Must match MC_BRIDGE in minecraft-twingate.sh, which routes the server's address to it.
      com.docker.network.bridge.name: mc-twingate0
    ipam:
      config:
        - subnet: "${MC_SUBNET}"
          ip_range: "${MC_IP_RANGE}"
EOF
}

# ---------- run and verify ----------

compose() { docker compose --project-directory "$MC_DIR" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

# .State.Running stays true while Docker restarts a crashing container, so read .State.Status.
container_state() {
	docker inspect --type container -f '{{.State.Status}} {{.RestartCount}}' "$1" 2>/dev/null || echo "missing ?"
}

restart_count() { docker inspect --type container -f '{{.RestartCount}}' "$1" 2>/dev/null || echo "?"; }

check_containers() {
	rc=0
	for name in minecraft-server twingate-connector; do
		state=$(container_state "$name")
		printf '  %-20s status=%s restarts=%s\n' "$name" "${state% *}" "${state#* }" >&2
		[ "${state% *}" = running ] || rc=1
	done
	return "$rc"
}

# Ready means running and either healthy (the image's own mc-health check) or showing "Done ("
# in the current run's log. Health covers a long run whose Done line has rotated out of the
# logs; the log line is quicker on a first start, before the 2-minute health start period ends.
minecraft_ready() {
	ready_state=$(docker inspect --type container -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.StartedAt}}' minecraft-server 2>/dev/null) || return 1
	read -r ready_status ready_health ready_started <<EOF
$ready_state
EOF
	[ "$ready_status" = running ] || return 1
	[ "$ready_health" != healthy ] || return 0
	docker logs --since "$ready_started" minecraft-server 2>&1 | grep -q 'Done ('
}

wait_ready() {
	log "Waiting up to ${MC_WAIT}s for Minecraft to finish starting (the first start downloads the server)"
	waited=0 mc_restarts=$(restart_count minecraft-server)
	until minecraft_ready; do
		[ "$waited" -lt "$MC_WAIT" ] || {
			warn "Minecraft is not ready yet. Follow it with: docker compose --project-directory $MC_DIR logs -f minecraft"
			return 1
		}
		[ "$(restart_count minecraft-server)" = "$mc_restarts" ] ||
			die "minecraft-server crashed and is restarting. Check: docker compose --project-directory $MC_DIR logs minecraft"
		sleep 5
		waited=$((waited + 5))
	done
	log "Minecraft is up"
}

# connector_state: the Connector's last "State: X" log line in its current run (Offline,
# Authentication, Online, Error...). Bad tokens leave it running, in State: Error.
connector_state() {
	cs_started=$(docker inspect --type container -f '{{.State.StartedAt}}' twingate-connector 2>/dev/null) || return 0
	docker logs --since "$cs_started" twingate-connector 2>&1 | sed -n 's/.*State: \([A-Za-z]*\).*/\1/p' | tail -n 1
}

# An Error can be a passing network fault, so only the state at the end of the window counts.
wait_connector() {
	waited=0 tg_state=""
	while [ "$waited" -lt 60 ]; do
		tg_state=$(connector_state)
		[ "$tg_state" != Online ] || {
			log "Twingate Connector is online"
			return 0
		}
		sleep 5
		waited=$((waited + 5))
	done
	[ "$tg_state" != Error ] ||
		die "The Twingate Connector is in State: Error, usually because its tokens were rejected. Generate a new pair, put it in $ENV_FILE, run update. Logs: docker compose --project-directory $MC_DIR logs twingate-connector"
	# A long-running Connector's State lines can rotate out of its logs, leaving none to read.
	warn "The Twingate Connector is not shown online after 60s (last logged state: ${tg_state:-none}). Check the Admin Console or its logs."
}

next_steps() {
	cat <<EOF

Next, in the Twingate Admin Console:
  1. Check the Connector's Controller and Relay statuses both say Connected.
  2. Resources > Add Resource on this Remote Network: address $MC_SERVER_IP, TCP port 25565.
  3. Grant it to a group such as "Minecraft Players" (and remove Everyone).
Players connect the Twingate Client, then add the server $MC_SERVER_IP in Minecraft Java Edition.
World data: $MC_DIR/data (back it up). Settings: $ENV_FILE (mode 600).
EOF
}

# The container names are fixed, so refuse to touch ones that another folder (or something
# other than Compose) created: Compose would otherwise repoint them at this folder's empty data.
check_ownership() {
	for name in minecraft-server twingate-connector; do
		owner=$(docker inspect --type container -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null) ||
			continue
		[ "$owner" = "$MC_DIR" ] ||
			die "A container named $name already exists and belongs to '${owner:-no Compose project}', not $MC_DIR. Use that --dir, or remove it."
	done
}

# network_changed: notes, before .env is rewritten, whether the bridge's subnet or range changes.
# Older Compose releases reuse an existing network as it is, so start_stack then takes the
# stack down first (the world is a bind mount, so it stays) and Compose rebuilds the network.
network_changed() {
	NET_CHANGED=0
	# A network from before the fixed bridge name has to be rebuilt to get it.
	net_bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$NET_NAME" 2>/dev/null) ||
		net_bridge=$MC_BRIDGE
	[ "$net_bridge" = "$MC_BRIDGE" ] || NET_CHANGED=1
	[ -f "$ENV_FILE" ] || return 0
	[ "$(env_get MC_SUBNET)" = "$MC_SUBNET" ] && [ "$(env_get MC_IP_RANGE)" = "$MC_IP_RANGE" ] || NET_CHANGED=1
}

# A Twingate Client on this same host routes the server's address into its tunnel (a /32 via
# sdwan0, metric 25). That route also catches the internet's replies to the server once they
# are un-NATed, so the server can't download or check logins with Mojang ("Authentication servers
# are down"). A /32 to the bridge with metric 1 wins over it; local players then reach the server
# directly. The bridge's routes go with the bridge, so a systemd unit adds it again after a reboot.
pin_route() {
	ip_bin=$(command -v ip) || {
		warn "No ip command: if a Twingate Client runs on this host, the server can't reach the internet."
		return 0
	}
	if [ ! -d /run/systemd/system ]; then
		"$ip_bin" route replace "$MC_SERVER_IP/32" dev "$MC_BRIDGE" metric 1 ||
			warn "Could not add the route from $MC_SERVER_IP to $MC_BRIDGE (see above)."
		warn "No systemd: the route to $MC_SERVER_IP is lost on reboot. Run update after each one."
		return 0
	fi
	# Docker creates the bridge as it starts, so wait for it rather than trust the ordering. A
	# removed stack has no network: then the unit does nothing instead of failing every boot.
	docker_bin=$(command -v docker)
	write_file "$ROUTE_UNIT" 644 <<EOF
# Generated by minecraft-twingate.sh (docs/minecraft-twingate.md).
[Unit]
Description=Route $MC_SERVER_IP to the Minecraft bridge, past a Twingate Client on this host
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '$docker_bin network inspect $NET_NAME >/dev/null 2>&1 || exit 0; i=0; until $ip_bin link show $MC_BRIDGE >/dev/null 2>&1; do [ \$\$i -lt 60 ] || exit 1; i=\$\$((i + 1)); sleep 1; done; exec $ip_bin route replace $MC_SERVER_IP/32 dev $MC_BRIDGE metric 1'

[Install]
WantedBy=docker.service
EOF
	# Best effort: the route only matters with a Twingate Client here, so never stop the stack for it.
	{ systemctl daemon-reload && systemctl enable --quiet "${ROUTE_UNIT##*/}" && systemctl restart "${ROUTE_UNIT##*/}"; } || {
		warn "Could not set up ${ROUTE_UNIT##*/} (see above). With a Twingate Client on this host, the server can't reach the internet."
		return 0
	}
	log "Routed $MC_SERVER_IP to $MC_BRIDGE (kept across reboots by ${ROUTE_UNIT##*/})"
}

start_stack() {
	# Pull first, so a registry or network failure stops the script while the old stack still runs.
	compose pull
	[ "${NET_CHANGED:-0}" = 0 ] || {
		log "The bridge network's subnet or name changed: taking the stack down so Compose rebuilds it"
		compose down
	}
	[ "$MC_VERSION" != LATEST ] || [ ! -d "$MC_DIR/data/world" ] ||
		warn "VERSION is LATEST: a new Minecraft release upgrades the world, which can't be undone. Back up $MC_DIR/data, or pin --version."
	# Create the network first, so the route is in place before the server starts downloading.
	compose up --no-start
	pin_route
	compose up -d
	tg_restarts=$(restart_count twingate-connector)
	mc_ready=1
	wait_ready || mc_ready=0
	# wait_connector also gives a crash loop time to show in RestartCount, even when
	# wait_ready returns at once on an unchanged update.
	wait_connector
	check_containers || die "A container is not running (see above). Check: docker compose --project-directory $MC_DIR logs"
	[ "$(restart_count twingate-connector)" = "$tg_restarts" ] ||
		die "twingate-connector keeps restarting. Check the tokens in $ENV_FILE, then: docker compose --project-directory $MC_DIR logs twingate-connector"
	next_steps
	[ "$mc_ready" = 1 ] || die "Minecraft did not finish starting within ${MC_WAIT}s (see the warning above)."
}

# ---------- commands ----------

parse_flags() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--accept-eula) MC_EULA=TRUE && shift && continue ;;
		--replace-conflicts) REPLACE=1 INSTALL_ONLY=$1 && shift && continue ;;
		--dry-run) DRY_RUN=1 INSTALL_ONLY=$1 && shift && continue ;;
		-h | --help) usage && exit 0 ;;
		--dir | --network | --memory | --type | --version | --subnet | --codename) ;;
		*) die "Unknown option: $1 (try --help)" ;;
		esac
		[ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)"
		case "$2" in -*) die "$1 needs a value, not '$2'" ;; esac
		case "$1" in
		--dir) MC_DIR=$2 ;;
		--network) TG_NETWORK=$2 ;;
		--memory) MC_MEMORY=$2 ;;
		--type) MC_TYPE=$2 ;;
		--version) MC_VERSION=$2 ;;
		--subnet) MC_SUBNET=$2 ;;
		--codename) CODENAME=$2 INSTALL_ONLY=$1 ;;
		esac
		shift 2
	done
	matches '/[A-Za-z0-9._/-]*' "$MC_DIR" || die "--dir must be an absolute path without spaces: $MC_DIR"
	# Compose labels containers with the cleaned path, so clean it the same way: no // or trailing /.
	MC_DIR=$(printf '%s\n' "$MC_DIR" | sed -e 's#//*#/#g' -e 's#\(.\)/$#\1#')
	case "$MC_DIR/" in
	// | */../* | */./*) die "--dir must be a dedicated folder: not /, and no . or .. parts" ;;
	/bin/ | /boot/ | /dev/ | /etc/ | /home/ | /lib/ | /lib64/ | /media/ | /mnt/ | /opt/ | /proc/ | /root/ | /run/ | /sbin/ | /srv/ | /sys/ | /tmp/ | /usr/ | /var/)
		die "--dir must be a dedicated folder, not the system or home folder $MC_DIR itself, such as /opt/minecraft-server"
		;;
	esac
	# Nor a folder one level under /home, /usr or /var, such as a home directory or /var/lib.
	# (A case glob's * also matches /, so test what is left after the prefix instead.)
	for top in /home /usr /var; do
		case "$MC_DIR" in "$top"/*) ;; *) continue ;; esac
		case "${MC_DIR#"$top"/}" in */*) ;; *) die "--dir must be a dedicated folder, not the system or home folder $MC_DIR itself, such as $MC_DIR/minecraft-server" ;; esac
	done
	matches '[a-z]*' "$CODENAME" || die "Invalid --codename '$CODENAME'"
	matches '[0-9]{1,5}' "$MC_WAIT" || die "MC_WAIT must be a number of seconds, such as 600"
	ENV_FILE=$MC_DIR/.env
	COMPOSE_FILE=$MC_DIR/compose.yaml
	# Never overwrite another app's Compose project or .env that happens to live in --dir.
	for owned in "$COMPOSE_FILE" "$ENV_FILE"; do
		[ ! -f "$owned" ] || [ ! -r "$owned" ] || grep -q 'Generated by minecraft-twingate.sh' "$owned" ||
			die "$owned exists and was not written by this script. Choose another --dir."
	done
	for other in docker-compose.yml docker-compose.yaml compose.yml; do
		[ ! -e "$MC_DIR/$other" ] || die "$MC_DIR/$other belongs to another Compose project. Choose another --dir."
	done
	# The container chowns /data to UID 1000 and :Z relabels it, so never adopt someone else's data/.
	[ ! -d "$MC_DIR/data" ] || [ -z "$(ls -A "$MC_DIR/data")" ] || { [ -f "$ENV_FILE" ] && [ ! -r "$ENV_FILE" ]; } ||
		grep -qs 'Generated by minecraft-twingate.sh' "$ENV_FILE" ||
		die "$MC_DIR/data already holds files that this script didn't set up. Choose another --dir."
}

main() {
	cmd=${1:-help}
	[ "$#" -eq 0 ] || shift
	case "$cmd" in
	help | -h | --help) usage && return 0 ;;
	install | update | status) ;;
	*) die "Unknown command: $cmd (try --help)" ;;
	esac
	args=$*
	parse_flags "$@"
	[ -z "$INSTALL_ONLY" ] || [ "$cmd" = install ] || die "$INSTALL_ONLY works with install only."
	# Plain sudo resets the environment, so the hint keeps every setting the caller exported.
	[ "$DRY_RUN" = 1 ] || [ "$(id -u)" -eq 0 ] || {
		keep=""
		# A bare script name would make sudo search PATH for it.
		case "$0" in */*) self=$0 ;; *) self=./$0 ;; esac
		[ -x "$0" ] || self="sh $self"
		for var in TG_NETWORK TG_ACCESS_TOKEN TG_REFRESH_TOKEN MC_DIR MC_MEMORY MC_TYPE MC_VERSION MC_SUBNET \
			MC_DIFFICULTY MC_MAX_PLAYERS MC_MOTD MC_OPS MC_SEED MC_EULA MC_IMAGE_TAG MC_WAIT; do
			env | grep -q "^$var=" && keep="$keep${keep:+,}$var"
		done
		die "Run as root, for example: sudo ${keep:+--preserve-env=$keep }$self $cmd${args:+ $args}"
	}
	[ "$cmd" = install ] || [ -f "$ENV_FILE" ] || die "Nothing installed in $MC_DIR. Run install first."
	case "$cmd" in
	install)
		if docker_present; then
			[ -z "$CODENAME" ] || warn "--codename has no effect: Docker is already installed."
		else
			detect_os
		fi
		resolve_config
		check_memory
		ensure_docker
		if [ "$DRY_RUN" = 1 ]; then
			# The preview always goes to a temp folder with the tokens blanked out: a .env left in
			# --dir would count as an install, and update would start what was only previewed.
			ENV_FILE=$(mktemp -d)/.env
			COMPOSE_FILE=${ENV_FILE%/.env}/compose.yaml
			TG_ACCESS_TOKEN=REDACTED TG_REFRESH_TOKEN=REDACTED
			write_config
			log "Dry run: config written to ${ENV_FILE%/.env}; no packages or containers touched."
			return 0
		fi
		check_ownership
		network_changed
		write_config
		start_stack
		;;
	update)
		resolve_config
		check_memory
		docker_up
		check_ownership
		network_changed
		write_config
		start_stack
		;;
	status)
		# Read-only and lenient: no prompts or validation, so a bad hand edit can't hide the state.
		MC_SERVER_IP=$(env_get MC_SERVER_IP)
		compose ps || warn "docker compose ps failed (see above); checking the containers directly."
		check_containers || warn "A container needs attention."
		if minecraft_ready; then
			log "Minecraft is ready"
		else
			warn "Minecraft has not finished starting."
		fi
		log "Twingate Connector state: $(connector_state)"
		[ -z "$MC_SERVER_IP" ] || ! command -v ip >/dev/null 2>&1 || [ -n "$(ip route show exact "$MC_SERVER_IP/32" dev "$MC_BRIDGE" 2>/dev/null)" ] ||
			warn "No route from $MC_SERVER_IP to $MC_BRIDGE: with a Twingate Client on this host, the server can't reach the internet. Run update."
		next_steps
		;;
	esac
}

main "$@"
