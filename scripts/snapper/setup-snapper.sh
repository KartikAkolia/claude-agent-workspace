#!/usr/bin/env bash
# setup-snapper.sh: install Snapper and a "root" config (the name Debian's apt hook and
# snapper-boot.service expect) for a Btrfs root on Debian/apt; historical. Verifies ALLOW_USERS
# as the invoking non-root user.
# Docs: docs/btrfs-snapshots-snapper.md

set -euo pipefail

die() {
	echo "setup-snapper.sh: $*" >&2
	exit 1
}

root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
[ "$root_fstype" = btrfs ] || die "/ is ${root_fstype:-of unknown type}, not btrfs; snapper's root config needs a Btrfs root."
command -v apt >/dev/null 2>&1 || die "apt not found; this script is Debian/apt-only (Debian's snapper package and its apt hook)."

TARGET_USER=""
if [ "$(id -u)" -ne 0 ]; then
	TARGET_USER="$(id -un)"
elif [ -n "${SUDO_USER:-}" ]; then
	TARGET_USER="$SUDO_USER"
elif [ -n "${PKEXEC_UID:-}" ]; then
	TARGET_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] ||
	die "can't tell which non-root user to verify with; run it as that user, or through sudo or pkexec from that user's session."
# TARGET_USER goes into a sed expression run as root: allow plain login names only.
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "refusing unusual user name '$TARGET_USER' for ALLOW_USERS"

sudo apt install -y snapper
if [ ! -e /etc/snapper/configs/root ]; then
	sudo snapper -c root create-config /
else
	echo "/etc/snapper/configs/root already exists, skipping create-config"
fi
sudo sed -i \
	-e "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$TARGET_USER\"/" \
	-e 's/^SYNC_ACL=.*/SYNC_ACL="yes"/' \
	/etc/snapper/configs/root
sudo systemctl restart snapperd.service
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer

echo "--- /etc/snapper/configs/root ---"
sudo cat /etc/snapper/configs/root
echo "--- timers ---"
systemctl is-enabled snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer
echo "--- test snapshot as $TARGET_USER (should NOT need sudo — confirms ALLOW_USERS took effect) ---"
sudo -u "$TARGET_USER" snapper -c root create --description "setup-snapper.sh verification"
sudo -u "$TARGET_USER" snapper -c root list
