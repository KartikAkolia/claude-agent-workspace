#!/usr/bin/env bash
# rss-stack.sh
# Installs and runs a self-hosted RSS stack with Docker Compose: FreshRSS (reader),
# RSS-Bridge (feeds for sites without one) and optionally cloudflared (Cloudflare Tunnel).
# Works on Debian, Ubuntu and Raspberry Pi OS, on amd64 or arm64.
#
# Usage (as root):
#   rss-stack.sh install [options]   first install, or re-apply settings
#   rss-stack.sh update              back up, re-apply settings, pull newer images
#   rss-stack.sh backup              tar.gz of config and data, keeps the newest 7
#   rss-stack.sh status              containers, architecture, health
#   rss-stack.sh credentials         print logins and internal URLs
#
# Install options (each one can also be set as an environment variable):
#   --domain rss.example.com   public hostname served by the tunnel   (DOMAIN)
#   --tunnel-token TOKEN       Cloudflare Tunnel token                 (TUNNEL_TOKEN)
#   --tz Europe/London         time zone, defaults to the host's       (TZ_NAME)
#   --user admin               FreshRSS admin username                 (ADMIN_USER)
#   --port 8080                host port for FreshRSS                  (LAN_PORT)
#   --dir /opt/rss-stack       config/data dir, pass to every command  (STACK_DIR)
#
# Re-running install keeps the passwords in .env. Later, prefer update: it backs up first.
# If Docker is missing, install runs Docker's get.docker.com script as root.
# Rootless Docker: install with DOCKER_HOST set; it is saved as STACK_DOCKER_HOST in .env.
# DRY_RUN=1 install writes the config files without touching apt or Docker.

set -Eeuo pipefail
umask 077

STACK_DIR="${STACK_DIR:-/opt/rss-stack}"
DOMAIN="${DOMAIN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TZ_NAME="${TZ_NAME:-}"
ADMIN_USER="${ADMIN_USER:-}"
LAN_PORT="${LAN_PORT:-}"
KEEP_BACKUPS=7
DRY_RUN="${DRY_RUN:-0}"

FRESHRSS_IMAGE="freshrss/freshrss:latest"
RSSBRIDGE_IMAGE="rssbridge/rss-bridge:latest"
CLOUDFLARED_IMAGE="cloudflare/cloudflared:latest"
ADMIN_PW="" API_PW="" BIND="" PROFILES="" BASE_URL="" ARCH="" TMP=""

log() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() {
	printf '[x] %s\n' "$*" >&2
	exit 1
}
# Subshells ($(...) and <(...)) exit quietly; the main shell reports the failure once.
trap '((BASHPID == $$)) || exit 1; die "Failed at line $LINENO: $BASH_COMMAND"' ERR
trap 'rm -f ${TMP:+"$TMP"}' EXIT

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
compose() { docker compose --project-directory "$STACK_DIR" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
retry() {
	local n=$1
	shift
	until "$@"; do
		((--n > 0)) || return 1
		sleep 2
	done
}
gen_secret() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
image_arch() { docker image inspect -f '{{.Architecture}}' "$1" 2>/dev/null || echo missing; }
tunnel_up() { grep -q "Registered tunnel connection" < <(docker logs cloudflared 2>&1); }
write_file() {
	TMP="$(mktemp "$1.XXXXXX")"
	cat >"$TMP"
	mv "$TMP" "$1"
	log "Wrote $1"
}

env_get() {
	[[ -f "$ENV_FILE" ]] || return 0
	grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# Precedence: flag or environment variable, then the saved .env, then the default.
pick() {
	local -n ref=$1
	ref="${ref:-$(env_get "$2")}"
	ref="${ref:-$3}"
}

# ---------- preflight ----------

check_os() {
	# shellcheck disable=SC1091
	. /etc/os-release
	case " ${ID:-} ${ID_LIKE:-} " in
	*" debian "* | *" ubuntu "* | *" raspbian "*) ;;
	*) die "Supported: Debian, Ubuntu, Raspberry Pi OS. Found: ${PRETTY_NAME:-unknown}" ;;
	esac
}

detect_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "Unsupported CPU: $(uname -m). This stack needs amd64 or arm64." ;;
	esac
	# A 64-bit kernel with a 32-bit userland (older Pi OS images) would pull armhf images.
	local userland
	userland="$(dpkg --print-architecture 2>/dev/null || echo "$ARCH")"
	[[ "$userland" == "$ARCH" ]] ||
		die "Kernel is $ARCH but the OS userland is $userland. Reinstall with the 64-bit OS image."
	log "Architecture: $ARCH"
}

install_deps() {
	command -v curl >/dev/null 2>&1 && return 0
	(umask 022 && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl)
}

install_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		log "Installing Docker Engine with the official get.docker.com script"
		TMP="$(mktemp)"
		curl -fsSL https://get.docker.com -o "$TMP"
		(umask 022 && DRY_RUN="" sh "$TMP")
		rm -f "$TMP"
	fi
	# DOCKER_HOST (rootless Docker, say) means another daemon is in use: leave the system one alone.
	[[ -n "$DOCKER_HOST" ]] || systemctl enable --now docker >/dev/null 2>&1 || true
	docker info >/dev/null 2>&1 ||
		die "No Docker daemon at ${DOCKER_HOST:-the default socket}. For rootless Docker, re-run with sudo --preserve-env=DOCKER_HOST"
	docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing. Install docker-compose-plugin."
}

# ---------- config ----------

resolve_config() {
	pick DOMAIN DOMAIN ""
	pick TUNNEL_TOKEN TUNNEL_TOKEN ""
	pick ADMIN_USER ADMIN_USER admin
	pick LAN_PORT LAN_PORT 8080
	pick TZ_NAME TZ "$(timedatectl show -p Timezone --value 2>/dev/null || true)"
	pick ADMIN_PW ADMIN_PASSWORD "$(gen_secret)"
	pick API_PW API_PASSWORD "$(gen_secret)"
	# Saved, so cron, update and status reach the daemon the stack was installed on.
	pick DOCKER_HOST STACK_DOCKER_HOST ""
	TZ_NAME="${TZ_NAME:-UTC}"

	[[ "$LAN_PORT" =~ ^[1-9][0-9]{0,4}$ && LAN_PORT -lt 65536 ]] || die "Invalid port: $LAN_PORT"
	[[ "$ADMIN_USER" =~ ^[A-Za-z0-9]{1,39}$ ]] || die "FreshRSS usernames are 1-39 letters and digits: $ADMIN_USER"
	[[ "$DOMAIN" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || die "Invalid domain: $DOMAIN"
	[[ "$TUNNEL_TOKEN" =~ ^([A-Za-z0-9][A-Za-z0-9+/=_-]*)?$ ]] || die "Invalid tunnel token"
	[[ "$TZ_NAME" =~ ^[A-Za-z][A-Za-z0-9_+/-]*$ ]] || die "Invalid time zone: $TZ_NAME"
	[[ "$DOCKER_HOST" =~ ^(unix:///[A-Za-z0-9._/-]+)?$ ]] || die "DOCKER_HOST must be a local unix:/// socket"
	[[ -z "$DOCKER_HOST" ]] || export DOCKER_HOST

	# With a tunnel, FreshRSS listens on loopback only: the tunnel is the way in.
	BIND=0.0.0.0 PROFILES=""
	[[ -z "$TUNNEL_TOKEN" ]] || BIND=127.0.0.1 PROFILES=tunnel
	local ip
	ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
	BASE_URL="http://${ip:-127.0.0.1}:$LAN_PORT"
	[[ -z "$DOMAIN" ]] || BASE_URL="https://$DOMAIN"
	[[ -n "$DOMAIN" || -z "$TUNNEL_TOKEN" ]] || warn "Tunnel token without --domain: base URL falls back to the LAN address."
	[[ -z "$DOMAIN" || -n "$TUNNEL_TOKEN" ]] || warn "--domain without a tunnel token: you need your own reverse proxy."
}

write_config() {
	mkdir -p "$STACK_DIR/data/freshrss" "$STACK_DIR/data/extensions" "$STACK_DIR/backups"
	write_file "$ENV_FILE" <<EOF
# Generated by rss-stack.sh. Keep this file private: it holds passwords.
TZ=$TZ_NAME
LAN_BIND=$BIND
LAN_PORT=$LAN_PORT
DOMAIN=$DOMAIN
BASE_URL=$BASE_URL
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PW
API_PASSWORD=$API_PW
TUNNEL_TOKEN=$TUNNEL_TOKEN
COMPOSE_PROFILES=$PROFILES
FRESHRSS_IMAGE=$FRESHRSS_IMAGE
RSSBRIDGE_IMAGE=$RSSBRIDGE_IMAGE
CLOUDFLARED_IMAGE=$CLOUDFLARED_IMAGE
STACK_DOCKER_HOST=$DOCKER_HOST
EOF
	write_file "$COMPOSE_FILE" <<'EOF'
# Generated by rss-stack.sh. Edit rss-stack.sh instead and re-run install.
name: rss-stack

x-common: &common
  restart: unless-stopped
  networks: [rss]
  labels: [com.centurylinklabs.watchtower.enable=false] # updates stay manual: rss-stack.sh update
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
  freshrss:
    <<: *common
    image: ${FRESHRSS_IMAGE}
    container_name: freshrss
    environment:
      TZ: ${TZ}
      CRON_MIN: "3,33"
      # FreshRSS 1.30+ blocks private networks. This replaces the list in System configuration.
      INTERNAL_HOST_ALLOWLIST: "rssbridge:80"
      # Applied on first start only. Later base URL changes use cli/reconfigure.php.
      FRESHRSS_INSTALL: >-
        --api-enabled
        --base-url ${BASE_URL}
        --default-user ${ADMIN_USER}
        --language en
      FRESHRSS_USER: >-
        --user ${ADMIN_USER}
        --password ${ADMIN_PASSWORD}
        --api-password ${API_PASSWORD}
        --language en
    volumes:
      - ./data/freshrss:/var/www/FreshRSS/data
      - ./data/extensions:/var/www/FreshRSS/extensions
    ports:
      - "${LAN_BIND}:${LAN_PORT}:80"

  # Internal only. FreshRSS reaches it at http://rssbridge/
  rssbridge:
    <<: *common
    image: ${RSSBRIDGE_IMAGE}
    container_name: rssbridge

  cloudflared:
    <<: *common
    image: ${CLOUDFLARED_IMAGE}
    container_name: cloudflared
    profiles: [tunnel]
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN}
    depends_on: [freshrss]

networks:
  rss: {}
EOF
}

install_self() {
	[[ "$(realpath "$0")" == "$(realpath -m "$STACK_DIR/rss-stack.sh")" ]] ||
		install -m 750 "$0" "$STACK_DIR/rss-stack.sh"
}

install_cron() {
	write_file /etc/cron.d/rss-stack <<EOF
30 3 * * 0 root $STACK_DIR/rss-stack.sh backup --dir $STACK_DIR >>/var/log/rss-stack.log 2>&1
EOF
	chmod 644 /etc/cron.d/rss-stack
}

# ---------- images ----------

# Docker can silently pull another architecture, so confirm what arrived.
pull_native() {
	docker pull -q --platform "linux/$ARCH" "$1" >/dev/null && [[ "$(image_arch "$1")" == "$ARCH" ]]
}

pull_images() {
	local img
	for img in "$FRESHRSS_IMAGE" "$RSSBRIDGE_IMAGE" ${PROFILES:+"$CLOUDFLARED_IMAGE"}; do
		pull_native "$img" || die "Could not pull a native $ARCH image of $img"
		log "Pulled $img ($ARCH)"
	done
}

# ---------- verify ----------

check_containers() {
	local svc svcs running restarts image rc=0
	svcs="$(compose config --services)" || return 1
	while read -r svc; do
		read -r running restarts image < <(docker inspect -f \
			'{{.State.Running}} {{.RestartCount}} {{.Config.Image}}' "$svc" 2>/dev/null || echo "false ? none")
		printf '  %-12s running=%-5s restarts=%-3s arch=%s\n' "$svc" "$running" "$restarts" "$(image_arch "$image")"
		[[ "$running" == true && "$(image_arch "$image")" == "$ARCH" ]] || rc=1
	done <<<"$svcs"
	return "$rc"
}

verify() {
	retry 60 curl -fs --max-time 5 -o /dev/null "http://127.0.0.1:$LAN_PORT/" ||
		die "FreshRSS is not answering. Check: sudo docker logs freshrss"
	log "FreshRSS answers on port $LAN_PORT"
	[[ -z "$PROFILES" ]] || retry 15 tunnel_up || warn "Tunnel has not registered yet. Check: sudo docker logs cloudflared"
	check_containers || warn "One or more containers need attention (see above)."
}

apply_base_url() {
	compose exec -T --user www-data freshrss php ./cli/reconfigure.php --base-url "$BASE_URL" >/dev/null 2>&1 ||
		warn "Could not update base URL. Set it in FreshRSS under Administration > System configuration."
}

# ---------- commands ----------

cmd_install() {
	local uid gid dir
	check_os
	[[ "$ADMIN_PW" =~ ^[A-Za-z0-9]{7,72}$ && "$API_PW" =~ ^[A-Za-z0-9]{7,72}$ ]] ||
		die "ADMIN_PASSWORD and API_PASSWORD in $ENV_FILE must be 7-72 letters and digits"
	[[ "$DRY_RUN" == 0 ]] || {
		write_config
		return 0
	}
	[[ -f "$0" ]] || die "Run rss-stack.sh from a saved file, not a pipe: cron needs a copy."
	install_deps
	install_docker
	pull_images
	write_config
	# Bind-mount folders belong to the daemon's user (DOCKER_HOST's socket owner, else root), who may
	# need to pass through the stack dir. That stays root-owned: root's cron runs the script there.
	# Their group too: host group 0 is unmapped under rootless Docker, so FreshRSS could not regroup them.
	uid=0
	[[ -z "$DOCKER_HOST" ]] || uid="$(stat -c %u "${DOCKER_HOST#unix://}")"
	gid="$(id -g "$uid")"
	[[ "$uid" == 0 ]] || chmod o+x "$STACK_DIR" "$STACK_DIR/data"
	for dir in "$STACK_DIR/data/freshrss" "$STACK_DIR/data/extensions"; do
		[[ "$(stat -c %u "$dir")" == "$uid" ]] || chown -R "$uid:$gid" "$dir"
	done
	install_self
	install_cron
	compose up -d --remove-orphans
	verify
	apply_base_url
}

cmd_backup() {
	local file old running
	file="$STACK_DIR/backups/rss-$(date +%Y%m%d-%H%M%S).tar.gz"
	running="$(docker inspect --type container -f '{{.State.Running}}' freshrss 2>/dev/null || true)"
	# A short stop keeps the SQLite database consistent while it is copied.
	compose stop freshrss >/dev/null 2>&1 || true
	tar -czf "$file" -C "$STACK_DIR" .env compose.yaml data || rm -f "$file"
	[[ "$running" != true ]] || compose start freshrss >/dev/null || die "FreshRSS did not restart after the backup. Check: sudo docker logs freshrss"
	[[ -f "$file" ]] || die "Backup failed"
	old=("$STACK_DIR"/backups/rss-*.tar.gz)
	((${#old[@]} <= KEEP_BACKUPS)) || rm -f "${old[@]:0:${#old[@]}-KEEP_BACKUPS}"
	log "Backup written: $file"
}

cmd_credentials() {
	cat <<EOF
FreshRSS          $BASE_URL
  username        $ADMIN_USER
  password        $ADMIN_PW
Mobile apps (Google Reader API)
  server          $BASE_URL/api/greader.php
  API password    $API_PW

Use these inside FreshRSS when adding feeds:
  RSS-Bridge      http://rssbridge/
  Full text       feed settings > Advanced > Article CSS selector on original website

Passwords live in $ENV_FILE (mode 600).
EOF
	[[ -z "$PROFILES" ]] || printf '%s\n' \
		"Next: in Cloudflare Zero Trust, point the tunnel's public hostname at http://freshrss:80" \
		"and protect it with an Access policy (bypass /api/* so phone apps can sync)."
}

# getopts has no long options, so flags are parsed by hand. Values are validated in resolve_config.
parse_flags() {
	local var
	while (($#)); do
		case "$1" in
		--domain) var=DOMAIN ;;
		--tunnel-token) var=TUNNEL_TOKEN ;;
		--tz) var=TZ_NAME ;;
		--user) var=ADMIN_USER ;;
		--port) var=LAN_PORT ;;
		--dir) var=STACK_DIR ;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "Unknown option: $1 (try --help)" ;;
		esac
		[[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 needs a value (try --help)"
		printf -v "$var" '%s' "$2"
		shift 2
	done
	[[ "$STACK_DIR" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "--dir must be an absolute path without spaces: $STACK_DIR"
	ENV_FILE="$STACK_DIR/.env"
	COMPOSE_FILE="$STACK_DIR/compose.yaml"
}

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	help | -h | --help)
		usage
		return 0
		;;
	install | update | backup | status | credentials) ;;
	*) die "Unknown command: $cmd (try --help)" ;;
	esac
	parse_flags "$@"
	[[ "$DRY_RUN" == 0 || "$DRY_RUN $cmd" == "1 install" ]] || die "DRY_RUN must be 0, or 1 with install"
	[[ "$DRY_RUN" == 0 ]] || log "Dry run: config files only, apt and Docker untouched."
	[[ "$DRY_RUN" == 1 || $EUID -eq 0 ]] || die "Run as root, for example: sudo $0 $cmd"
	[[ "$cmd" == install || -f "$ENV_FILE" ]] || die "Nothing installed in $STACK_DIR. Run install first."
	detect_arch
	resolve_config
	case "$cmd" in
	install)
		cmd_install
		cmd_credentials
		;;
	update)
		cmd_backup
		cmd_install
		docker image prune -f >/dev/null
		log "Update complete"
		;;
	backup) cmd_backup ;;
	status) verify ;;
	credentials) cmd_credentials ;;
	esac
}

main "$@"
