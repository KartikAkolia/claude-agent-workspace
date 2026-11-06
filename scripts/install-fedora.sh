#!/usr/bin/env bash
# install-fedora.sh — post-install setup for EL10 (Rocky / AlmaLinux /
# CentOS Stream / RHEL 10) and Fedora, on VMs and bare metal.
#
# Replicates the rocky10 VM setup from 2026-11-06:
#   dnf.conf tuning, CRB + EPEL (EL only), build toolchain + kernel headers,
#   CachyOS kernel (COPR), SELinux off (selinux=0 + config), firewalld off,
#   guest agent on KVM/QEMU (or open-vm-tools on VMware), fstrim.timer,
#   OpenJDK, fzf + zoxide + starship with a managed ~/.bashrc block,
#   and optionally Cockpit removal / a new hostname.
#
# Every step checks current state first, so reruns are safe. Nothing prompts:
# behaviour is set by flags (see --help). Use --dry-run to print the commands
# without changing anything.
#
# Network trust: zoxide (EL only — Fedora packages it) and starship (neither
# packages it) come from their upstream install scripts on GitHub/starship.rs.
# Each script is downloaded to a temp file and run as the target user, never
# as root, and only writes to that user's ~/.local/bin.
#
# Not supported: Fedora Atomic / rpm-ostree systems (Silverblue, Kinoite,
# Bazzite) — they need rpm-ostree, not dnf.

set -Eeuo pipefail

readonly SCRIPT_NAME="install-fedora.sh"
readonly LOG_FILE="/var/log/install-fedora.log"
readonly COPR_CACHYOS="bieszczaders/kernel-cachyos"
readonly ZOXIDE_INSTALLER="https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh"
readonly STARSHIP_INSTALLER="https://starship.rs/install.sh"
readonly BASHRC_BEGIN="# >>> install-fedora.sh >>>"
readonly BASHRC_END="# <<< install-fedora.sh <<<"

# Defaults (the user chose SELinux off, firewalld off and the CachyOS kernel
# as defaults; Cockpit removal is opt-in).
DRY_RUN=0
TARGET_USER=""
NEW_HOSTNAME=""
KERNEL_VARIANT="cachyos"
DISABLE_SELINUX=1
DISABLE_FIREWALL=1
REMOVE_COCKPIT=0
JAVA_VERSION="25"
DO_BUILD_TOOLS=1
DO_CLI_TOOLS=1
DO_GUEST_TOOLS=1

# Filled in by detect_system.
OS_ID=""
OS_FAMILY="" # el | fedora
IS_DNF5=0
VIRT="none"
TARGET_HOME=""
NEED_REBOOT=0
CURRENT_STEP="startup"
SUMMARY=()

# OS_RELEASE_FILE lets --dry-run be exercised against a sample os-release.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

usage() {
	cat <<EOF
Usage: sudo ./$SCRIPT_NAME [options]

Post-install setup for Rocky/Alma/CentOS Stream/RHEL 10 and Fedora.
Safe to rerun; each step skips work that is already done.

Options:
  --dry-run              Print what would run; change nothing.
  --user NAME            User whose shell tools and ~/.bashrc are set up
                         (default: \$SUDO_USER).
  --hostname NAME        Set the static hostname.
  --kernel VARIANT       CachyOS kernel: cachyos (default), lts, server, rt,
                         or none. cachyos/rt need an x86-64-v3 CPU; on older
                         CPUs the script falls back to lts.
  --keep-selinux         Leave SELinux as it is (default: disable it).
  --keep-firewall        Leave firewalld as it is (default: stop and mask it).
  --remove-cockpit       Stop Cockpit and remove all cockpit* packages.
  --java VERSION         OpenJDK version to install: 21, 25 (default), or none.
  --no-build-tools       Skip the compiler toolchain, -devel libraries and
                         kernel headers.
  --no-cli-tools         Skip fzf, zoxide, starship and the ~/.bashrc block.
  --no-guest-tools       Skip the VM guest agent even when a VM is detected.
  -h, --help             Show this help.

Changes that need a reboot (kernel, SELinux) are reported at the end.
Log: $LOG_FILE
EOF
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}
note() { SUMMARY+=("$*"); }

# Runs a command, or prints it under --dry-run.
run() {
	if ((DRY_RUN)); then
		printf '[dry-run] %s\n' "${*@Q}"
		return 0
	fi
	"$@"
}

# Runs a command as the target user with that user's HOME.
as_user() {
	run runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }

pkg_available() {
	[[ -n "$(dnf -q repoquery "$1" 2>/dev/null)" ]]
}

# Best-effort install: tries the whole list at once, then one at a time so a
# single missing package doesn't block the rest. Missing ones are reported.
dnf_install_soft() {
	(($#)) || return 0
	if ((DRY_RUN)); then
		run dnf install -y "$@"
		return 0
	fi
	dnf install -y "$@" && return 0
	warn "batch install failed; retrying one package at a time"
	local pkg failed=()
	for pkg in "$@"; do
		dnf install -y "$pkg" || failed+=("$pkg")
	done
	if ((${#failed[@]})); then
		warn "not installed: ${failed[*]}"
		note "Packages not installed (unavailable or failed): ${failed[*]}"
	fi
}

on_error() {
	local status=$? line=$1
	# Report once, from the main shell; subshells inherit the trap (set -E).
	((BASH_SUBSHELL == 0)) || exit "$status"
	printf '\033[1;31merror:\033[0m step "%s" failed at line %s (exit %s). See %s\n' \
		"$CURRENT_STEP" "$line" "$status" "$LOG_FILE" >&2
	exit "$status"
}

parse_args() {
	while (($#)); do
		local opt="$1" val="" has_val=0
		case "$opt" in
		--*=*)
			val="${opt#*=}"
			opt="${opt%%=*}"
			has_val=1
			;;
		esac
		case "$opt" in
		--user | --hostname | --kernel | --java)
			if ((! has_val)); then
				(($# >= 2)) || die "$opt needs a value"
				val="$2"
				shift
			fi
			[[ -n "$val" ]] || die "$opt needs a non-empty value"
			;;
		*)
			((! has_val)) || die "$opt does not take a value"
			;;
		esac
		case "$opt" in
		--dry-run) DRY_RUN=1 ;;
		--user) TARGET_USER="$val" ;;
		--hostname) NEW_HOSTNAME="$val" ;;
		--kernel) KERNEL_VARIANT="$val" ;;
		--java) JAVA_VERSION="$val" ;;
		--keep-selinux) DISABLE_SELINUX=0 ;;
		--keep-firewall) DISABLE_FIREWALL=0 ;;
		--remove-cockpit) REMOVE_COCKPIT=1 ;;
		--no-build-tools) DO_BUILD_TOOLS=0 ;;
		--no-cli-tools) DO_CLI_TOOLS=0 ;;
		--no-guest-tools) DO_GUEST_TOOLS=0 ;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "unknown option: $1 (see --help)" ;;
		esac
		shift
	done

	case "$KERNEL_VARIANT" in
	cachyos | lts | server | rt | none) ;;
	*) die "--kernel must be cachyos, lts, server, rt or none (got '$KERNEL_VARIANT')" ;;
	esac
	case "$JAVA_VERSION" in
	21 | 25 | none) ;;
	*) die "--java must be 21, 25 or none (got '$JAVA_VERSION')" ;;
	esac
	# Dot-separated DNS labels (an FQDN is fine), 253 characters at most.
	local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
	if [[ -n "$NEW_HOSTNAME" ]] &&
		{ ((${#NEW_HOSTNAME} > 253)) || [[ ! "$NEW_HOSTNAME" =~ ^$label(\.$label)*$ ]]; }; then
		die "invalid hostname: '$NEW_HOSTNAME'"
	fi
}

detect_system() {
	CURRENT_STEP="detect system"
	[[ -r "$OS_RELEASE_FILE" ]] || die "cannot read $OS_RELEASE_FILE"
	local ID="" VERSION_ID="" PRETTY_NAME=""
	# shellcheck source=/dev/null
	. "$OS_RELEASE_FILE"
	OS_ID="$ID"

	case "$ID" in
	rocky | almalinux | centos | rhel)
		[[ "${VERSION_ID%%.*}" == 10 ]] ||
			die "$PRETTY_NAME is not supported; EL needs major version 10"
		OS_FAMILY="el"
		;;
	fedora) OS_FAMILY="fedora" ;;
	*) die "unsupported OS '$ID' — this script targets EL10 and Fedora" ;;
	esac

	if [[ -e /run/ostree-booted ]]; then
		die "rpm-ostree (Atomic) systems are not supported; use rpm-ostree instead"
	fi

	if ((! DRY_RUN)) && ((EUID != 0)); then
		die "run as root: sudo ./$SCRIPT_NAME"
	fi

	if have dnf && [[ "$(readlink -f "$(command -v dnf)")" == *dnf5 ]]; then
		IS_DNF5=1
	fi

	if have systemd-detect-virt; then
		VIRT="$(systemd-detect-virt 2>/dev/null || true)"
		[[ -n "$VIRT" ]] || VIRT="none"
	fi

	TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
	if [[ -n "$TARGET_USER" ]]; then
		TARGET_HOME="$(getent passwd "$TARGET_USER" || true)"
		TARGET_HOME="$(cut -d: -f6 <<<"$TARGET_HOME")"
		[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] ||
			die "user '$TARGET_USER' not found or has no home directory"
	fi

	log "System: $PRETTY_NAME | family=$OS_FAMILY | dnf5=$IS_DNF5 | virt=$VIRT | user=${TARGET_USER:-<none>}"
}

step_hostname() {
	CURRENT_STEP="hostname"
	[[ -n "$NEW_HOSTNAME" ]] || return 0
	if [[ "$(hostnamectl --static 2>/dev/null)" == "$NEW_HOSTNAME" ]]; then
		log "Hostname already $NEW_HOSTNAME"
		return 0
	fi
	log "Setting hostname to $NEW_HOSTNAME"
	run hostnamectl set-hostname "$NEW_HOSTNAME"
	note "Hostname set to $NEW_HOSTNAME"
}

step_dnf_conf() {
	CURRENT_STEP="dnf.conf"
	local conf=/etc/dnf/dnf.conf tmp
	log "Tuning $conf (defaultyes, max_parallel_downloads=10, fastestmirror)"
	if ((DRY_RUN)); then
		printf '[dry-run] set defaultyes=True, max_parallel_downloads=10, fastestmirror=True under [main] in %s\n' "$conf"
		return 0
	fi
	[[ -f "$conf" ]] || printf '[main]\n' >"$conf"
	grep -q '^\[main\]' "$conf" || sed -i '1i [main]' "$conf"

	tmp="$(mktemp)"
	# Drop existing copies of the three keys, then re-add them under [main].
	sed -E '/^(defaultyes|max_parallel_downloads|fastestmirror)[[:space:]]*=/d' "$conf" |
		sed '/^\[main\]/a defaultyes=True\nmax_parallel_downloads=10\nfastestmirror=True' >"$tmp"
	if cmp -s "$tmp" "$conf"; then
		log "dnf.conf already tuned"
		rm -f "$tmp"
		return 0
	fi
	[[ -e "$conf.bak.install-fedora" ]] || cp -a "$conf" "$conf.bak.install-fedora"
	cat "$tmp" >"$conf" # keeps owner, mode and SELinux label
	rm -f "$tmp"
	note "dnf.conf tuned (backup: $conf.bak.install-fedora)"
}

step_repos() {
	CURRENT_STEP="repositories"
	[[ "$OS_FAMILY" == el ]] || return 0
	local enabled="" changed=0
	((DRY_RUN)) || enabled="$(dnf -q repolist --enabled 2>/dev/null || true)"

	if [[ "$enabled" =~ (^|[[:space:]])(crb|codeready-builder[^[:space:]]*)[[:space:]] ]]; then
		log "CRB already enabled"
	elif [[ "$OS_ID" == rhel ]]; then
		log "Enabling CodeReady Builder"
		if run subscription-manager repos --enable "codeready-builder-for-rhel-10-$(uname -m)-rpms"; then
			changed=1
		else
			warn "could not enable CodeReady Builder (is this RHEL host registered?)"
			note "CodeReady Builder not enabled — register with subscription-manager and rerun"
		fi
	else
		log "Enabling CRB"
		pkg_installed dnf-plugins-core || run dnf install -y dnf-plugins-core
		run dnf config-manager --set-enabled crb
		changed=1
	fi

	if pkg_installed epel-release; then
		log "EPEL already installed"
	else
		log "Installing EPEL"
		if [[ "$OS_ID" == rhel ]]; then
			run dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
		else
			run dnf install -y epel-release
		fi
		changed=1
	fi

	if ((changed)); then
		run dnf makecache
		note "CRB/EPEL enabled"
	fi
}

step_build_tools() {
	CURRENT_STEP="build tools"
	((DO_BUILD_TOOLS)) || return 0
	log "Installing compiler toolchain, -devel libraries and kernel headers"
	if [[ "$OS_FAMILY" == el ]]; then
		run dnf group install -y "Development Tools"
	else
		run dnf group install -y development-tools c-development
	fi
	dnf_install_soft \
		cmake meson ninja-build pkgconf-pkg-config clang llvm gdb perl \
		python3-devel python3-pip \
		openssl-devel zlib-devel bzip2-devel xz-devel libffi-devel \
		readline-devel sqlite-devel ncurses-devel libcurl-devel \
		libxml2-devel elfutils-libelf-devel \
		kernel-devel kernel-headers dkms
	# Headers for the running kernel; absent from the repos when the running
	# kernel is older than the newest available one. A running CachyOS kernel
	# gets its headers from kernel-cachyos*-devel-matched (step_kernel).
	if [[ "$(uname -r)" == *cachy* ]]; then
		log "Running a CachyOS kernel; its headers come from the -devel-matched package"
	elif ! pkg_installed "kernel-devel-$(uname -r)"; then
		run dnf install -y "kernel-devel-$(uname -r)" ||
			note "kernel-devel-$(uname -r) unavailable; update the kernel, reboot and rerun"
	fi
	note "Build toolchain installed"
}

# Prints 1 if UEFI Secure Boot is enabled, 0 otherwise.
secure_boot_enabled() {
	if have mokutil; then
		local state
		state="$(mokutil --sb-state 2>/dev/null || true)"
		[[ "$state" == *"SecureBoot enabled"* ]] && echo 1 || echo 0
		return 0
	fi
	local var
	var="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1 || true)"
	if [[ -n "$var" ]] && [[ "$(od -An -t u1 -j4 -N1 "$var" 2>/dev/null | tr -d ' ')" == 1 ]]; then
		echo 1
	else
		echo 0
	fi
}

cpu_has_x86_64_v3() {
	local out
	out="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
	[[ "$out" == *"x86-64-v3 (supported"* ]]
}

step_kernel() {
	CURRENT_STEP="CachyOS kernel"
	[[ "$KERNEL_VARIANT" != none ]] || return 0
	if [[ "$(uname -m)" != x86_64 ]]; then
		warn "CachyOS kernels are x86_64 only; skipping"
		note "CachyOS kernel skipped (not x86_64)"
		return 0
	fi
	if [[ "$(secure_boot_enabled)" == 1 ]]; then
		warn "Secure Boot is on and COPR kernels are unsigned; skipping the CachyOS kernel"
		note "CachyOS kernel skipped: Secure Boot is enabled (disable it or sign the kernel, then rerun)"
		return 0
	fi
	if [[ "$KERNEL_VARIANT" == cachyos || "$KERNEL_VARIANT" == rt ]] && ! cpu_has_x86_64_v3; then
		warn "CPU lacks x86-64-v3; using kernel-cachyos-lts instead of $KERNEL_VARIANT"
		KERNEL_VARIANT="lts"
	fi

	local pkg="kernel-cachyos" pattern
	[[ "$KERNEL_VARIANT" == cachyos ]] || pkg="kernel-cachyos-$KERNEL_VARIANT"
	case "$KERNEL_VARIANT" in
	# Seen on EL10: vmlinuz-7.3.1-1.cachyos1.el10.x86_64. The other variants'
	# release tags (cachylts, cachyserver, cachyrt) come from the COPR's
	# package versions and never contain "cachyos", so the globs can't overlap.
	cachyos) pattern='/boot/vmlinuz-*cachyos[0-9]*' ;;
	lts) pattern='/boot/vmlinuz-*cachylts*' ;;
	server) pattern='/boot/vmlinuz-*cachyserver*' ;;
	rt) pattern='/boot/vmlinuz-*cachyrt*' ;;
	esac

	if pkg_installed "$pkg"; then
		# Leave the boot default alone on reruns, so a deliberate rollback
		# to the stock kernel (grubby --set-default) sticks.
		log "$pkg already installed; boot default left as is"
	else
		log "Installing $pkg from COPR $COPR_CACHYOS"
		if ((IS_DNF5)); then
			pkg_installed dnf5-plugins || run dnf install -y dnf5-plugins
		else
			pkg_installed dnf-plugins-core || run dnf install -y dnf-plugins-core
		fi
		run dnf copr enable -y "$COPR_CACHYOS"
		run dnf install -y "$pkg" "$pkg-devel-matched"
		NEED_REBOOT=1

		# Make the kernel just installed the default boot entry.
		local newest=""
		if ((! DRY_RUN)); then
			newest="$(compgen -G "$pattern" | sort -V | tail -n1 || true)"
		fi
		if [[ -n "$newest" ]]; then
			if [[ "$(grubby --default-kernel 2>/dev/null)" != "$newest" ]]; then
				run grubby --set-default "$newest"
			fi
			log "Default kernel: $newest"
			note "Installed $pkg as the default kernel (reboot to use it)"
		elif ((DRY_RUN)); then
			printf '[dry-run] grubby --set-default <newest %s>\n' "$pattern"
			note "Installed $pkg (reboot to use it)"
		else
			warn "no $pattern found in /boot; default kernel left unchanged"
			note "Installed $pkg, but couldn't find it in /boot to make it the default — check: sudo grubby --info=ALL"
		fi
	fi

	# Module loading under SELinux, per the COPR's instructions. Not needed
	# when this run disables SELinux.
	if ((! DISABLE_SELINUX)) && have selinuxenabled && selinuxenabled; then
		run setsebool -P domain_kernel_load_modules on
	fi
}

step_selinux() {
	CURRENT_STEP="SELinux"
	((DISABLE_SELINUX)) || return 0
	log "Disabling SELinux (selinux=0 on every kernel + SELINUX=disabled)"
	# Runs after step_kernel so the CachyOS entries get the argument too.
	# --update-kernel=ALL also updates GRUB_CMDLINE_LINUX for future kernels.
	local args
	args="$(grubby --info=ALL 2>/dev/null | grep '^args=' || true)"
	if ((DRY_RUN)) || grep -vq 'selinux=0' <<<"$args"; then
		run grubby --update-kernel=ALL --args=selinux=0
		NEED_REBOOT=1
		note "selinux=0 added to all kernels (reboot to apply)"
	else
		log "selinux=0 already on every kernel"
	fi
	if [[ -f /etc/selinux/config ]] && ! grep -q '^SELINUX=disabled' /etc/selinux/config; then
		run sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
	fi
	# Stop enforcing now, without waiting for the reboot.
	if have getenforce && [[ "$(getenforce)" == Enforcing ]]; then
		run setenforce 0
	fi
}

step_firewall() {
	CURRENT_STEP="firewalld"
	((DISABLE_FIREWALL)) || return 0
	local units
	units="$(systemctl list-unit-files --no-legend firewalld.service 2>/dev/null || true)"
	if [[ "$units" != firewalld.service* ]]; then
		log "firewalld not installed"
		return 0
	fi
	if [[ "$(systemctl is-enabled firewalld 2>/dev/null)" == masked ]] &&
		! systemctl is-active -q firewalld; then
		log "firewalld already stopped and masked"
		return 0
	fi
	log "Stopping and masking firewalld"
	run systemctl disable --now firewalld
	run systemctl mask firewalld
	if [[ "$VIRT" == none ]]; then
		note "firewalld masked — bare metal: every listening port is now reachable from the LAN"
	else
		note "firewalld masked"
	fi
}

step_cockpit() {
	CURRENT_STEP="Cockpit"
	((REMOVE_COCKPIT)) || return 0
	local pkgs
	pkgs="$(rpm -qa --qf '%{NAME}\n' 'cockpit*' 2>/dev/null || true)"
	if [[ -z "$pkgs" ]]; then
		log "Cockpit not installed"
		return 0
	fi
	log "Removing Cockpit: $(tr '\n' ' ' <<<"$pkgs")"
	run systemctl disable --now cockpit.socket || true
	run dnf remove -y 'cockpit*'
	note "Cockpit removed"
}

step_guest_tools() {
	CURRENT_STEP="guest tools"
	run systemctl enable --now fstrim.timer
	((DO_GUEST_TOOLS)) || return 0
	case "$VIRT" in
	kvm | qemu)
		log "KVM/QEMU guest: installing qemu-guest-agent"
		pkg_installed qemu-guest-agent || run dnf install -y qemu-guest-agent
		# Starts only when the VM has an org.qemu.guest_agent.0 channel; the
		# unit is device-activated, so a missing channel is not an error here.
		run systemctl enable qemu-guest-agent
		if run systemctl start qemu-guest-agent; then
			note "qemu-guest-agent installed and running"
		else
			note "qemu-guest-agent installed but not running: add an org.qemu.guest_agent.0 channel to the VM"
		fi
		;;
	vmware)
		log "VMware guest: installing open-vm-tools"
		pkg_installed open-vm-tools || run dnf install -y open-vm-tools
		if run systemctl enable --now vmtoolsd; then
			note "open-vm-tools installed and running"
		else
			note "open-vm-tools installed but vmtoolsd failed to start"
		fi
		;;
	none) log "Bare metal: no guest agent needed" ;;
	*) log "Hypervisor '$VIRT': no guest agent handled by this script" ;;
	esac
}

step_java() {
	CURRENT_STEP="Java"
	[[ "$JAVA_VERSION" != none ]] || return 0
	local pkg="java-$JAVA_VERSION-openjdk-devel"
	if pkg_installed "$pkg"; then
		log "$pkg already installed"
		return 0
	fi
	log "Installing $pkg"
	dnf_install_soft "$pkg"
	if ((DRY_RUN)) || pkg_installed "$pkg"; then
		note "OpenJDK $JAVA_VERSION installed ($pkg)"
	fi
}

# Downloads an upstream installer and runs it as the target user.
run_user_installer() {
	local url="$1"
	shift
	if ((DRY_RUN)); then
		printf '[dry-run] as %s: download %s and run: sh <script> %s\n' "$TARGET_USER" "$url" "$*"
		return 0
	fi
	# $1 = URL, rest = installer arguments; the temp file is the user's own.
	# shellcheck disable=SC2016 # expanded by the inner sh, not here
	as_user sh -c '
		set -eu
		tmp="$(mktemp)"
		trap "rm -f \"\$tmp\"" EXIT
		curl -fsSL "$1" -o "$tmp"
		shift
		sh "$tmp" "$@"
	' sh "$url" "$@"
}

step_cli_tools() {
	CURRENT_STEP="CLI tools"
	((DO_CLI_TOOLS)) || return 0
	if [[ -z "$TARGET_USER" ]]; then
		warn "no target user (run with sudo or pass --user); skipping fzf/zoxide/starship"
		note "CLI tools skipped: no target user"
		return 0
	fi
	local bindir="$TARGET_HOME/.local/bin"

	log "Installing fzf"
	pkg_installed fzf || run dnf install -y fzf

	if have zoxide || [[ -x "$bindir/zoxide" ]]; then
		log "zoxide already installed"
	elif have dnf && pkg_available zoxide; then
		run dnf install -y zoxide
	else
		log "Installing zoxide from upstream into $bindir"
		as_user mkdir -p "$bindir"
		run_user_installer "$ZOXIDE_INSTALLER" --bin-dir "$bindir"
	fi

	if have starship || [[ -x "$bindir/starship" ]]; then
		log "starship already installed"
	else
		log "Installing starship from upstream into $bindir"
		as_user mkdir -p "$bindir"
		run_user_installer "$STARSHIP_INSTALLER" -b "$bindir" -y
	fi

	write_bashrc_block
	note "fzf, zoxide (z/zi) and starship set up for $TARGET_USER"
}

write_bashrc_block() {
	local rc="$TARGET_HOME/.bashrc" tmp
	log "Updating managed block in $rc"
	if ((DRY_RUN)); then
		printf '[dry-run] rewrite the %s ... %s block at the end of %s\n' "$BASHRC_BEGIN" "$BASHRC_END" "$rc"
		return 0
	fi
	# Read and write the file as the user, never as root, so a symlinked
	# ~/.bashrc can't redirect a root write elsewhere.
	if [[ -L "$rc" ]]; then
		warn "$rc is a symlink; not editing it. Add the block by hand (see $SCRIPT_NAME)"
		note ".bashrc not edited: it is a symlink"
		return 0
	fi
	[[ -e "$rc" ]] || as_user touch "$rc"
	local current
	current="$(
		as_user cat "$rc"
		printf x
	)"
	current="${current%x}"
	# A begin marker with no end marker would make the stripper drop the
	# rest of the file, so stop instead.
	if grep -qxF "$BASHRC_BEGIN" <<<"$current" && ! grep -qxF "$BASHRC_END" <<<"$current"; then
		warn "$rc has '$BASHRC_BEGIN' but no '$BASHRC_END'; fix it by hand, then rerun"
		note ".bashrc not edited: managed block is missing its end marker"
		return 0
	fi
	tmp="$(mktemp)"
	# Remove an earlier managed block and the hand-added lines from the
	# original manual setup, then append a fresh block. zoxide goes last, as
	# its docs require.
	awk -v b="$BASHRC_BEGIN" -v e="$BASHRC_END" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		skip { next }
		/^eval "\$\((fzf --bash|starship init bash|zoxide init bash[^)]*)\)"$/ { next }
		/^# (fzf: Ctrl-R history search|starship prompt|zoxide: smarter cd)/ { next }
		# Hold blank lines back so trailing ones are dropped, not stacked up.
		/^[[:space:]]*$/ { blank++; next }
		{ while (blank > 0) { print ""; blank-- } print }
	' <<<"$current" >"$tmp"
	local sep=""
	[[ ! -s "$tmp" ]] || sep=$'\n'
	{
		printf '%s' "$sep"
		printf '%s\n' "$BASHRC_BEGIN"
		cat <<'EOF'
# Managed by install-fedora.sh; edits inside this block are lost on rerun.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
if command -v javac >/dev/null 2>&1; then
	JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
	export JAVA_HOME
fi
if [[ $- == *i* ]]; then
	command -v fzf >/dev/null 2>&1 && eval "$(fzf --bash)"
	command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"
	# zoxide must stay last: z / zi
	command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
fi
EOF
		printf '%s\n' "$BASHRC_END"
	} >>"$tmp"
	if printf '%s' "$current" | cmp -s "$tmp" -; then
		log ".bashrc block already current"
		rm -f "$tmp"
		return 0
	fi
	[[ -e "$rc.bak.install-fedora" ]] || as_user cp -a "$rc" "$rc.bak.install-fedora"
	as_user tee "$rc" <"$tmp" >/dev/null # keeps the user's ownership and mode
	rm -f "$tmp"
}

print_summary() {
	printf '\n'
	if ((DRY_RUN)); then
		log "Summary (dry run: planned changes, nothing was modified)"
	else
		log "Summary"
	fi
	local line
	for line in "${SUMMARY[@]}"; do
		printf '  - %s\n' "$line"
	done
	((${#SUMMARY[@]})) || printf '  - nothing changed\n'
	if ((NEED_REBOOT)); then
		printf '\n'
		log "Reboot required for the kernel / SELinux changes. After rebooting, verify with:"
		printf '    uname -r                 # CachyOS kernel if one was installed\n'
		printf '    getenforce               # Disabled, unless --keep-selinux\n'
		printf '    sudo grubby --default-kernel\n'
	fi
}

main() {
	parse_args "$@"
	if ((! DRY_RUN)) && ((EUID == 0)); then
		exec > >(tee -a "$LOG_FILE") 2>&1
		printf '\n--- %s run %s ---\n' "$SCRIPT_NAME" "$(date -Is)"
	fi
	trap 'on_error $LINENO' ERR
	detect_system

	step_hostname
	step_dnf_conf
	step_repos
	step_build_tools
	step_kernel
	step_selinux
	step_firewall
	step_cockpit
	step_guest_tools
	step_java
	step_cli_tools

	CURRENT_STEP="summary"
	print_summary
}

main "$@"
