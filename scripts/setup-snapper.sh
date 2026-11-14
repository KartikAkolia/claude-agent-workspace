#!/usr/bin/env bash
# setup-snapper.sh — install and configure Snapper for Btrfs snapshots on
# asus-vivobook (single @rootfs subvolume, no separate @home).
#
# Debian/apt-only, and historical: written for the laptop's Debian install on
# Btrfs (2026-08-28). The laptop now runs CachyOS on ext4 with no snapper
# (docs/btrfs-snapshots-snapper.md). The script refuses to run unless / is
# Btrfs and apt is on PATH, since every step below assumes Debian's snapper
# package and its apt hook.
#
# Timeshift was considered first but ruled out: its Btrfs mode only supports
# Ubuntu-style @/@home subvolume layouts (upstream README: "BTRFS snapshots
# are supported only on BTRFS systems having an Ubuntu-type subvolume
# layout... non-standard BTRFS layouts remain unsupported"). This box's root
# subvolume is named @rootfs with no separate @home, so Timeshift's Btrfs
# mode would not work here. Snapper has no such naming requirement.
#
# Debian's snapper package ships a ready-made apt integration hook
# (/etc/apt/apt.conf.d/80snapper) that auto-snapshots before/after every
# dpkg-invoking apt operation — but it's hardcoded to look for a config
# named exactly "root" (same for the snapper-boot.service unit), which is
# why the config below MUST be created with that name.
#
# Companion runbook: docs/btrfs-snapshots-snapper.md

set -euo pipefail

root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
if [ "$root_fstype" != btrfs ]; then
	echo "setup-snapper.sh: / is ${root_fstype:-of unknown type}, not btrfs; snapper's root config needs a Btrfs root." >&2
	exit 1
fi
if ! command -v apt >/dev/null 2>&1; then
	echo "setup-snapper.sh: apt not found; this script is Debian/apt-only (Debian's snapper package and its apt hook)." >&2
	exit 1
fi

# The last step verifies ALLOW_USERS as the real non-root user: run as root,
# that check would pass even if ALLOW_USERS were broken, since root always
# bypasses it. Work the user out now, before changing anything: the caller
# itself, else whoever ran sudo (SUDO_USER) or pkexec (PKEXEC_UID). Plain
# root with neither is refused.
if [ "$(id -u)" -ne 0 ]; then
	TARGET_USER="$(id -un)"
elif [ -n "${SUDO_USER:-}" ]; then
	TARGET_USER="$SUDO_USER"
elif [ -n "${PKEXEC_UID:-}" ]; then
	TARGET_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
else
	TARGET_USER=""
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
	echo "setup-snapper.sh: can't tell which non-root user to verify with; run it as that user, or through sudo or pkexec from that user's session." >&2
	exit 1
fi
# The name goes into ALLOW_USERS through sed below, so allow only plain login
# names (no sed metacharacters, quotes or spaces).
if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
	echo "setup-snapper.sh: refusing unusual user name '$TARGET_USER' for ALLOW_USERS" >&2
	exit 1
fi

sudo apt install -y snapper

# Create the "root" config over the live root subvolume. This also creates
# the nested /.snapshots subvolume that stores snapshot data. Idempotent —
# skipped if already created by a previous run.
if [ ! -e /etc/snapper/configs/root ]; then
	sudo snapper -c root create-config /
else
	echo "/etc/snapper/configs/root already exists, skipping create-config"
fi

# Let the invoking user (not just root) create/list/diff snapshots without
# sudo, and sync that permission onto the .snapshots directory's ACL. This is
# the same user the final check runs as.
sudo sed -i \
	-e "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$TARGET_USER\"/" \
	-e 's/^SYNC_ACL=.*/SYNC_ACL="yes"/' \
	/etc/snapper/configs/root

# apt's postinst starts snapperd (enabled via sysinit.target.wants) *before*
# create-config runs above, so it comes up with no configs loaded. Restart it
# now so it re-reads /etc/snapper/configs/root and actually honors ALLOW_USERS
# -- without this, every non-root `snapper` call fails with "No permissions."
# even though the config file on disk looks correct.
sudo systemctl restart snapperd.service

# Timeline (hourly/daily/monthly/yearly cadence per the config's
# TIMELINE_LIMIT_* defaults), cleanup (enforces those retention limits daily),
# and boot (one snapshot per boot) — all three ship with the package and are
# gated on config "root" existing (see snapper-boot.service's ConditionPathExists).
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer

echo "--- /etc/snapper/configs/root ---"
sudo cat /etc/snapper/configs/root
echo "--- timers ---"
systemctl is-enabled snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer

# Verify as the real non-root user worked out at the top.
echo "--- test snapshot as $TARGET_USER (should NOT need sudo — confirms ALLOW_USERS took effect) ---"
sudo -u "$TARGET_USER" snapper -c root create --description "setup-snapper.sh verification"
sudo -u "$TARGET_USER" snapper -c root list
