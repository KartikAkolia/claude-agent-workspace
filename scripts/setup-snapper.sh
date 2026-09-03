#!/usr/bin/env bash
# setup-snapper.sh — install and configure Snapper for Btrfs snapshots on
# asus-vivobook (single @rootfs subvolume, no separate @home).
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

sudo apt install -y snapper

# Create the "root" config over the live root subvolume. This also creates
# the nested /.snapshots subvolume that stores snapshot data. Idempotent —
# skipped if already created by a previous run.
if [ ! -e /etc/snapper/configs/root ]; then
	sudo snapper -c root create-config /
else
	echo "/etc/snapper/configs/root already exists, skipping create-config"
fi

# Let kartik (not just root) create/list/diff snapshots without sudo, and
# sync that permission onto the .snapshots directory's ACL.
sudo sed -i \
	-e 's/^ALLOW_USERS=.*/ALLOW_USERS="kartik"/' \
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

# Verify as the real non-root user regardless of whether this script itself
# was invoked with or without sudo -- run as root, this check would trivially
# pass even if ALLOW_USERS were broken, since root always bypasses it.
TARGET_USER="${SUDO_USER:-$USER}"
echo "--- test snapshot as $TARGET_USER (should NOT need sudo — confirms ALLOW_USERS took effect) ---"
sudo -u "$TARGET_USER" snapper -c root create --description "setup-snapper.sh verification"
sudo -u "$TARGET_USER" snapper -c root list
