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
# Control-flow rule: never nest if statements; use guard clauses and helpers.
# Enforced by scripts/test_install_fedora.py.
# Nothing prompts:
# behaviour is set by flags (see --help). Use --dry-run to print the commands
# without changing anything.
#
# Network trust: fallback installers are pinned and SHA-256 checked, then run
# as a non-root user with no_new_privs and a clean environment. They fetch
# upstream release binaries over HTTPS; zoxide also installs local man pages.
# Release binaries remain trusted upstream content, not independently signed here.
#
# Not supported: Fedora Atomic / rpm-ostree systems (Silverblue, Kinoite,
# Bazzite) — they need rpm-ostree, not dnf.

set -Eeuo pipefail

readonly SCRIPT_NAME="install-fedora.sh"
readonly LOG_FILE="/var/log/install-fedora.log"
readonly COPR_CACHYOS="bieszczaders/kernel-cachyos"
readonly ZOXIDE_INSTALLER="https://raw.githubusercontent.com/ajeetdsouza/zoxide/v0.10.0/install.sh"
readonly ZOXIDE_SHA256="0c25aed6cce9d56ee0596c9a5df8cbe99ffd0f7a7054de0262234dd268b61404"
readonly STARSHIP_INSTALLER="https://raw.githubusercontent.com/starship/starship/v1.27.0/install/install.sh"
readonly STARSHIP_SHA256="52c64f14a558034ebeb1907ea9364e802b32474576fd3e68265f73bc33cc8fbb"
readonly USER_PATH="/usr/local/bin:/usr/bin:/bin"
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
OS_VERSION=""
IS_DNF5=0
VIRT="none"
TARGET_HOME=""
NEED_REBOOT=0
CURRENT_STEP="startup"
SUMMARY=()
PARTIAL_FAILURE=0
SUMMARY_READY=0
BOOT_DEFAULT_TO_RESTORE=""

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
                         CPUs with x86-64-v2 the script falls back to lts.
                         Older CPUs keep the stock kernel.
  --keep-selinux         Leave SELinux as it is (default: disable it).
  --keep-firewall        Leave firewalld as it is (default: stop and mask it).
  --remove-cockpit       Stop Cockpit and remove all cockpit* packages.
  --java VERSION         OpenJDK version to install: 21, 25 (default), or none.
  --no-build-tools       Skip the compiler toolchain, -devel libraries and
                         kernel headers.
  --no-cli-tools         Skip fzf, zoxide, starship and the ~/.bashrc block.
  --no-guest-tools       Skip the VM guest agent even when a VM is detected.
  -h, --help             Show this help.

Exit status: 0 complete, 2 requested components incomplete, other nonzero fatal.
Changes that need a reboot are also reported after failures or interruption.
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
	run runuser -u "$TARGET_USER" -- setpriv --no-new-privs env -i \
		HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
		PATH="$TARGET_HOME/.local/bin:$USER_PATH" "$@"
}
user_have() {
	((DRY_RUN)) && return 1
	# shellcheck disable=SC2016 # Expanded by the target shell.
	as_user sh -c 'command -v "$1" >/dev/null 2>&1' sh "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }

pkg_available() {
	((DRY_RUN)) && return 1
	local result
	result="$(dnf -q repoquery "$1")" || return 1
	[[ -n "$result" ]]
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
	((${#failed[@]})) || return 0
	PARTIAL_FAILURE=1
	warn "not installed: ${failed[*]}"
	note "Incomplete installation: ${failed[*]}"
}

on_error() {
	local status=$? line=$1
	((BASH_SUBSHELL == 0)) || exit "$status"
	printf 'error: step "%s" failed at line %s (exit %s). See %s\n' \
		"$CURRENT_STEP" "$line" "$status" "$LOG_FILE" >&2
	exit "$status"
}
on_exit() {
	local status=$?
	trap - EXIT ERR INT TERM
	((SUMMARY_READY)) || exit "$status"
	restore_boot_default || { ((status != 0)) || status=1; }
	print_summary
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
	((DRY_RUN)) || [[ "$OS_RELEASE_FILE" == /etc/os-release ]] || die "OS_RELEASE_FILE override requires --dry-run"
	[[ -r "$OS_RELEASE_FILE" ]] || die "cannot read $OS_RELEASE_FILE"
	local ID="" VERSION_ID="" PRETTY_NAME=""
	# shellcheck source=/dev/null
	. "$OS_RELEASE_FILE"
	OS_ID="$ID"
	OS_VERSION="$VERSION_ID"

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
	detect_target_user

	log "System: $PRETTY_NAME | family=$OS_FAMILY | dnf5=$IS_DNF5 | virt=$VIRT | user=${TARGET_USER:-<none>}"
}

detect_target_user() {
	[[ -n "$TARGET_USER" ]] || return 0
	local entry uid
	entry="$(getent passwd "$TARGET_USER")" || die "unknown user '$TARGET_USER'"
	IFS=: read -r TARGET_USER _ uid _ _ TARGET_HOME _ <<<"$entry"
	[[ "$uid" != 0 ]] || die "target user must not be root (UID 0)"
	[[ "$TARGET_HOME" == /* && -d "$TARGET_HOME" ]] || die "target user has no absolute home directory"
}
require_commands() {
	local tool
	for tool in "$@"; do
		have "$tool" || die "required command missing: $tool (install it before running this script)"
	done
}
preflight() {
	CURRENT_STEP="preflight"
	((DRY_RUN)) && return 0
	require_commands dnf rpm python3 systemctl flock
	((DISABLE_SELINUX)) && require_commands grubby getenforce setenforce
	[[ -z "$NEW_HOSTNAME" ]] || require_commands hostnamectl
	[[ "$OS_ID" != rhel ]] || require_commands subscription-manager
	((DO_CLI_TOOLS == 0)) || [[ -z "$TARGET_USER" ]] || require_commands runuser setpriv curl sha256sum tar
	check_kernel_repository
}
check_kernel_repository() {
	[[ "$KERNEL_VARIANT" != none && "$(uname -m)" == x86_64 ]] || return 0
	[[ "$(secure_boot_state)" == disabled ]] || return 0
	select_kernel_variant
	[[ "$KERNEL_VARIANT" != none ]] || return 0
	require_commands grubby kernel-install
	((DISABLE_SELINUX)) || require_commands selinuxenabled setsebool
	local pkg=kernel-cachyos chroot="fedora-$OS_VERSION"
	[[ "$KERNEL_VARIANT" == cachyos ]] || pkg="kernel-cachyos-$KERNEL_VARIANT"
	pkg_installed "$pkg" && pkg_installed "$pkg-devel-matched" && return 0
	[[ "$OS_FAMILY" != el ]] || chroot=epel-10
	require_commands curl
	local url="https://download.copr.fedorainfracloud.org/results/$COPR_CACHYOS/$chroot-x86_64/repodata/repomd.xml"
	curl --fail --silent --show-error --location --head --proto '=https' --proto-redir '=https' \
		--connect-timeout 15 --max-time 60 "$url" >/dev/null || die "COPR repository unavailable for $chroot; no setup changes made"
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

step_package_health() {
	CURRENT_STEP="RPM integrity"
	((DRY_RUN)) && return 0
	# Exclude obsoletes checks: COPR's metapackage has self-matching legacy Provides.
	dnf check --dependencies --duplicates ||
		die "RPM dependency/duplicate errors detected; repair interrupted package transactions, pass 'dnf check --dependencies --duplicates', then rerun"
}
detect_pending_reboot() {
	have grubby || return 0
	local boot runtime
	boot="$(grubby --default-kernel 2>/dev/null || true)"
	if [[ -n "$boot" && "$boot" != "/boot/vmlinuz-$(uname -r)" ]]; then
		NEED_REBOOT=1
	fi
	((DISABLE_SELINUX)) && have getenforce || return 0
	runtime="$(getenforce 2>/dev/null || true)"
	[[ "$runtime" != Disabled ]] || return 0
	all_kernels_disable_selinux && NEED_REBOOT=1
	return 0
}

step_dnf_conf() {
	CURRENT_STEP="dnf.conf"
	log "Tuning /etc/dnf/dnf.conf"
	if ((DRY_RUN)); then
		printf '[dry-run] atomically tune only [main] in /etc/dnf/dnf.conf\n'
		return 0
	fi
	update_dnf_conf /etc/dnf/dnf.conf
	note "dnf.conf tuned (existing original backed up once)"
}
update_dnf_conf() {
	python3 - "$1" <<'PYTHON'
import os, pathlib, re, shutil, signal, sys, tempfile
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)
for signum in (signal.SIGHUP, signal.SIGTERM):
    signal.signal(signum, interrupted)
p = pathlib.Path(sys.argv[1])
if p.is_symlink():
    sys.exit("refusing symlinked dnf.conf")
old = p.read_bytes() if p.exists() else b""
lines = old.decode().splitlines(keepends=True)
section = None
seen = False
out = []
keys = "defaultyes=True\nmax_parallel_downloads=10\nfastestmirror=True\n"
for line in lines:
    match = re.match(r"^\s*\[([^]]+)\]\s*(?:[#;].*)?$", line)
    section = match[1] if match else section
    if match and section == "main":
        out.extend([line.rstrip("\r\n") + "\n", keys])
        seen = True
        continue
    if section == "main" and re.match(r"^\s*(defaultyes|max_parallel_downloads|fastestmirror)\s*=", line):
        continue
    out.append(line)
new = (("" if seen else "[main]\n" + keys) + "".join(out)).encode()
if new == old:
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=".install-fedora-", dir=p.parent)
try:
    with os.fdopen(fd, "wb") as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    if p.exists():
        shutil.copystat(p, tmp)
        os.chown(tmp, p.stat().st_uid, p.stat().st_gid)
    if not p.exists():
        os.chmod(tmp, 0o644)
    if p.exists() and not os.path.lexists(str(p) + ".bak.install-fedora"):
        shutil.copy2(p, str(p) + ".bak.install-fedora")
    if (p.read_bytes() if p.exists() else b"") != old:
        sys.exit("dnf.conf changed concurrently; refusing replacement")
    os.replace(tmp, p)
    directory = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYTHON
}

ensure_dnf_plugins() {
	local pkg=dnf-plugins-core
	((IS_DNF5 == 0)) || pkg=dnf5-plugins
	pkg_installed "$pkg" || run dnf install -y "$pkg"
}
enable_crb() {
	if [[ "$OS_ID" == rhel ]]; then
		run subscription-manager repos --enable "codeready-builder-for-rhel-10-$(uname -m)-rpms"
		return 0
	fi
	ensure_dnf_plugins
	if ((IS_DNF5)); then
		run dnf config-manager setopt crb.enabled=1
		return 0
	fi
	run dnf config-manager --set-enabled crb
}
step_repos() {
	CURRENT_STEP="repositories"
	[[ "$OS_FAMILY" == el ]] || return 0
	local enabled="" changed=0
	((DRY_RUN)) || enabled="$(dnf -q repolist --enabled)"
	if [[ ! "$enabled" =~ (^|[[:space:]])(crb|codeready-builder[^[:space:]]*)[[:space:]] ]]; then
		enable_crb
		changed=1
	fi
	if ! pkg_installed epel-release; then
		install_epel
		changed=1
	fi
	((changed)) || return 0
	run dnf makecache
	note "CRB/EPEL enabled"
}
install_epel() {
	case "$OS_ID" in
	rhel | centos) run dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm ;;
	*) run dnf install -y epel-release ;;
	esac
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
			{
				PARTIAL_FAILURE=1
				note "kernel-devel-$(uname -r) unavailable; update the kernel, reboot and rerun"
			}
	fi
	note "Build toolchain processed; see incomplete package notices, if any"
}

# Returns text: enabled, disabled, or unknown. Failed probes are not disabled.
efi_booted() { [[ -d /sys/firmware/efi ]]; }
secure_boot_state() {
	local state="" var value
	have mokutil && state="$(LC_ALL=C mokutil --sb-state 2>/dev/null || true)"
	case "$state" in
	*"SecureBoot enabled"*)
		echo enabled
		return 0
		;;
	*"SecureBoot disabled"* | *"EFI variables are not supported on this system"*)
		# Only a BIOS boot independently proves Secure Boot is inapplicable.
		efi_booted || {
			echo disabled
			return 0
		}
		[[ "$state" != *"SecureBoot disabled"* ]] || {
			echo disabled
			return 0
		}
		;;
	esac
	efi_booted || {
		echo disabled
		return 0
	}
	var="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1 || true)"
	value="$(od -An -t u1 -j4 -N1 "${var:-/nonexistent}" 2>/dev/null | tr -d ' ' || true)"
	case "$value" in
	1) echo enabled ;;
	0) echo disabled ;;
	*) echo unknown ;;
	esac
}

cpu_supports_level() {
	local out
	out="$(LC_ALL=C /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
	[[ "$out" == *"x86-64-v$1 (supported"* ]]
}
select_kernel_variant() {
	cpu_supports_level 2 || {
		note "CachyOS skipped: CPU lacks x86-64-v2"
		KERNEL_VARIANT=none
		return 0
	}
	case "$KERNEL_VARIANT" in
	cachyos | rt)
		cpu_supports_level 3 && return 0
		warn "CPU lacks x86-64-v3; using LTS (x86-64-v2)"
		KERNEL_VARIANT=lts
		;;
	esac
}

step_kernel() {
	CURRENT_STEP="CachyOS kernel"
	[[ "$KERNEL_VARIANT" != none ]] || return 0
	[[ "$(uname -m)" == x86_64 ]] || {
		note "CachyOS skipped: architecture is not x86_64"
		return 0
	}
	local secure
	secure="$(secure_boot_state)"
	[[ "$secure" == disabled ]] || {
		note "CachyOS skipped: Secure Boot is $secure"
		return 0
	}
	select_kernel_variant
	[[ "$KERNEL_VARIANT" != none ]] || return 0
	local pkg=kernel-cachyos fresh=0
	[[ "$KERNEL_VARIANT" == cachyos ]] || pkg="kernel-cachyos-$KERNEL_VARIANT"
	pkg_installed "$pkg" || fresh=1
	install_kernel_packages "$pkg" "$fresh"
	ensure_kernel_boot_files "$pkg"
	if ((fresh)); then
		set_kernel_default "$pkg"
	fi
	if ((DISABLE_SELINUX == 0)) && have selinuxenabled && selinuxenabled; then
		run setsebool -P domain_kernel_load_modules on
	fi
}
install_kernel_packages() {
	local pkg="$1" fresh="$2"
	# Do not upgrade an already complete installation or change a deliberate rollback.
	if ((fresh == 0)) && pkg_installed "$pkg-devel-matched"; then
		log "$pkg and its development package already installed; boot default preserved"
		return 0
	fi
	ensure_dnf_plugins
	run dnf copr enable -y "$COPR_CACHYOS"
	# RPM scriptlets can change the default before boot-file generation finishes.
	if ((DRY_RUN == 0)); then
		BOOT_DEFAULT_TO_RESTORE="$(grubby --default-kernel)"
	fi
	((fresh == 0)) || NEED_REBOOT=1
	run dnf install -y "$pkg" "$pkg-devel-matched" || {
		restore_boot_default
		return 1
	}
	restore_boot_default
}
restore_boot_default() {
	[[ -n "$BOOT_DEFAULT_TO_RESTORE" ]] || return 0
	run grubby --set-default "$BOOT_DEFAULT_TO_RESTORE" || {
		warn "could not restore boot default $BOOT_DEFAULT_TO_RESTORE; inspect grubby --info=ALL"
		return 1
	}
	BOOT_DEFAULT_TO_RESTORE=""
}
kernel_boot_image() {
	local version
	# COPR owns /lib/modules/<release>/vmlinuz; kernel-install creates /boot files.
	version="$(rpm -ql "$1-core" | sed -nE 's#^/(usr/)?lib/modules/([^/]+)/vmlinuz$#\2#p' | sort -Vu | tail -n1)"
	[[ -n "$version" ]] || return 1
	printf '/boot/vmlinuz-%s\n' "$version"
}
kernel_boot_ready() {
	local image="$1" version="${1##*/vmlinuz-}"
	[[ -s "$image" && -s "/boot/initramfs-$version.img" ]] && grubby --info "$image" >/dev/null
}
ensure_kernel_boot_files() {
	local pkg="$1" image version
	if ((DRY_RUN)); then
		printf '[dry-run] verify and repair missing boot files for %s\n' "$pkg"
		return 0
	fi
	image="$(kernel_boot_image "$pkg")" || die "cannot locate installed $pkg kernel release"
	kernel_boot_ready "$image" && return 0
	version="${image##*/vmlinuz-}"
	log "Repairing interrupted boot-file generation for $version"
	BOOT_DEFAULT_TO_RESTORE="$(grubby --default-kernel)"
	NEED_REBOOT=1
	run kernel-install add "$version" "/lib/modules/$version/vmlinuz" || {
		restore_boot_default
		return 1
	}
	restore_boot_default
	kernel_boot_ready "$image" || die "boot files still incomplete for $version; inspect kernel-install output"
	note "Repaired $pkg boot files; existing boot default preserved on recovery"
}
set_kernel_default() {
	local pkg="$1" newest
	if ((DRY_RUN)); then
		printf '[dry-run] select newest boot entry for %s-core\n' "$pkg"
		return 0
	fi
	newest="$(kernel_boot_image "$pkg")" || die "cannot locate installed $pkg kernel release"
	[[ -f "$newest" ]] || die "cannot locate installed $pkg boot image: $newest"
	grubby --info "$newest" >/dev/null || die "no boot entry for $newest"
	[[ "$(grubby --default-kernel)" == "$newest" ]] || run grubby --set-default "$newest"
	note "Installed $pkg as default; reboot to use it"
}

all_kernels_disable_selinux() {
	local info
	info="$(grubby --info=ALL)" || return 1
	awk '
 /^args=/ {
  count++; line=$0; sub(/^args="?/, "", line); sub(/"$/, "", line)
  n=split(line, a, /[[:space:]]+/); found=0
  for (i=1; i<=n; i++) { if (a[i] == "selinux=0") found=1 }
  if (!found) bad=1
 }
 END { exit !(count && !bad) }
 ' <<<"$info"
}
step_selinux() {
	CURRENT_STEP="SELinux"
	((DISABLE_SELINUX)) || return 0
	local runtime
	runtime=unknown
	have getenforce && runtime="$(getenforce)"
	[[ "$runtime" == Disabled ]] || NEED_REBOOT=1
	if ((DRY_RUN)) || ! all_kernels_disable_selinux; then
		NEED_REBOOT=1
		run grubby --update-kernel=ALL --args=selinux=0
		note "selinux=0 configured on all kernels"
	fi
	if [[ -f /etc/selinux/config ]] && ! grep -q '^SELINUX=disabled$' /etc/selinux/config; then
		run sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
	fi
	[[ "$runtime" != Enforcing ]] || run setenforce 0
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
	run systemctl stop firewalld
	[[ "$(systemctl is-enabled firewalld 2>/dev/null)" == masked ]] || run systemctl disable firewalld
	run systemctl mask firewalld
	if [[ "$VIRT" == none ]]; then
		note "firewalld masked — review exposed listening services on this host"
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
	local url="$1" digest="$2"
	shift 2
	if ((DRY_RUN)); then
		printf '[dry-run] verify installer SHA-256 and run without privilege escalation as %s: %s\n' "$TARGET_USER" "$url"
		return 0
	fi
	# no_new_privs inherited from as_user prevents sudo/setuid escalation.
	# shellcheck disable=SC2016
	as_user sh -c '
  set -eu
  [ "$(id -u)" != 0 ] || exit 1
  tmp="$(mktemp -d)"
  trap '\''rm -rf -- "$tmp"'\'' EXIT HUP INT TERM
  curl --fail --silent --show-error --location --proto "=https" --proto-redir "=https" --connect-timeout 15 --max-time 120 "$1" -o "$tmp/install.sh"
  printf "%s  %s\n" "$2" "$tmp/install.sh" | sha256sum -c -
  shift 2
  sh "$tmp/install.sh" "$@"
 ' sh "$url" "$digest" "$@"
}
prepare_user_destination() {
	local bindir="$TARGET_HOME/.local/bin"
	as_user mkdir -p "$bindir" "$TARGET_HOME/.local/share/man"
	as_user test -w "$bindir"
	as_user test -w "$TARGET_HOME/.local/share/man"
}
ensure_zoxide() {
	user_have zoxide && return 0
	if pkg_available zoxide; then
		run dnf install -y zoxide
		return 0
	fi
	prepare_user_destination
	run_user_installer "$ZOXIDE_INSTALLER" "$ZOXIDE_SHA256" --bin-dir "$TARGET_HOME/.local/bin" --sudo /bin/false
}
ensure_starship() {
	user_have starship && return 0
	prepare_user_destination
	run_user_installer "$STARSHIP_INSTALLER" "$STARSHIP_SHA256" -b "$TARGET_HOME/.local/bin" -y -v v1.27.0
}

step_cli_tools() {
	CURRENT_STEP="CLI tools"
	((DO_CLI_TOOLS)) || return 0
	if [[ -z "$TARGET_USER" ]]; then
		warn "no target user (run with sudo or pass --user); skipping fzf/zoxide/starship"
		note "CLI tools skipped: no target user"
		return 0
	fi
	log "Installing fzf"
	pkg_installed fzf || run dnf install -y fzf

	ensure_zoxide
	ensure_starship

	write_bashrc_block
	note "fzf, zoxide (z/zi) and starship set up for $TARGET_USER"
}

write_bashrc_block() {
	local rc="$TARGET_HOME/.bashrc"
	if ((DRY_RUN)); then
		printf '[dry-run] validate markers and atomically update %s as %s\n' "$rc" "$TARGET_USER"
		return 0
	fi
	as_user python3 - "$rc" "$BASHRC_BEGIN" "$BASHRC_END" <<'PYTHON'
import os, pathlib, shutil, signal, sys, tempfile
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)
for signum in (signal.SIGHUP, signal.SIGTERM):
    signal.signal(signum, interrupted)
p = pathlib.Path(sys.argv[1])
begin, end = (s.encode() for s in sys.argv[2:])
if p.is_symlink() or (p.exists() and not p.is_file()):
    sys.exit("refusing nonregular or symlinked .bashrc")
if p.exists() and p.stat().st_uid != os.getuid():
    sys.exit(".bashrc must be owned by target user")
old = p.read_bytes() if p.exists() else b""
out = []
inside = False
for line in old.splitlines(keepends=True):
    marker = line.rstrip(b"\r\n")
    if marker == begin and inside:
        sys.exit("nested .bashrc begin marker; file unchanged")
    if marker == end and not inside:
        sys.exit("unmatched .bashrc end marker; file unchanged")
    if marker in (begin, end):
        inside = marker == begin
        continue
    if not inside:
        out.append(line)
if inside:
    sys.exit("unmatched .bashrc begin marker; file unchanged")
prefix = b"".join(out)
separator = b"\n" if prefix and not prefix.endswith(b"\n") else b""
block = b"""# Managed by install-fedora.sh; edits inside this block are lost on rerun.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
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
"""
new = prefix + separator + begin + b"\n" + block + end + b"\n"
if new == old:
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=".install-fedora-", dir=p.parent)
try:
    with os.fdopen(fd, "wb") as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    if p.exists():
        shutil.copystat(p, tmp)
    if p.exists() and not os.path.lexists(str(p) + ".bak.install-fedora"):
        shutil.copy2(p, str(p) + ".bak.install-fedora")
    if p.is_symlink() or (p.read_bytes() if p.exists() else b"") != old:
        sys.exit(".bashrc changed concurrently; refusing replacement")
    os.replace(tmp, p)
    directory = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYTHON
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
	trap 'on_error $LINENO' ERR
	detect_system
	preflight
	if ((! DRY_RUN)); then
		exec {INSTALL_LOCK}>/run/install-fedora.lock
		flock -n "$INSTALL_LOCK" || die "another install-fedora run is active"
		exec > >(tee -a "$LOG_FILE") 2>&1
		printf '\n--- %s run %s ---\n' "$SCRIPT_NAME" "$(date -Is)"
	fi
	SUMMARY_READY=1
	trap on_exit EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	detect_pending_reboot
	step_package_health
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
	((PARTIAL_FAILURE == 0)) || exit 2
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
