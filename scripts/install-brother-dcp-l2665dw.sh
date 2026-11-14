#!/usr/bin/env bash
# install-brother-dcp-l2665dw.sh — install Brother's official Linux CUPS
# driver for the DCP-L2665DW and register it as a CUPS printer queue.
#
# Exit status: 0 = a matching CUPS queue is verified present or updated;
# 1 = the install failed (no matching queue afterwards -- including a kept
# queue that disappeared -- or a precondition wasn't met);
# 2 = unverified -- an existing matching queue was kept and nothing about its
# visible configuration changed, so a non-root run can't tell whether the
# reinstall did anything (the warning explains how to get a verifiable run).
#
# Debian/Ubuntu only. Brother's installer picks deb or rpm packages by
# probing for the package tools, so on a host with rpm but no dpkg (Arch and
# CachyOS ship rpm in rpm-tools) it runs `rpm -ihv --nodeps --replacefiles
# --replacepkgs --ignorearch` as root, behind pacman's back, and still exits
# 0 when that fails. The script therefore refuses to run unless
# /etc/os-release names debian in ID or ID_LIKE and dpkg is on PATH, and on
# other hosts it prints the driverless IPP Everywhere route instead (the
# printer has IPP open on port 631, see below; `-m everywhere` itself hasn't
# been tried against it). OS_RELEASE overrides /etc/os-release for testing.
#
# Diagnosed 2026-08-30: CUPS itself (cups.service) is installed and running,
# but no printer queue exists yet (`lpstat -t` -> "No destinations added",
# /etc/cups/printers.conf absent) and no Brother driver/PPD packages were
# installed. The printer itself IS live on the LAN: 192.168.0.214, MAC OUI
# 94:dd:f8 (Brother Industries), web UI title "Brother DCP-L2665DW", ports
# 631 (IPP), 9100 (JetDirect raw), 80/443 (embedded web server) all open.
#
# Corroborated by the printer's own maintenance-info export
# (~/Downloads/mnt_info.csv, pulled from its embedded web UI): node name
# BRN94DDF84A8DB1 (matches the MAC above), model "Brother DCP-L2665DW",
# IP 192.168.0.214, serial E83140M4N926629, firmware 1.26/1.11, drum 98%
# / toner 90% life remaining -- same printer, independently confirmed.
#
# Brother's support page for this model
# (https://support.brother.com/g/b/downloadlist.aspx?c=gb&lang=en&prod=dcpl2665dw_eu&os=128)
# gates its "Linux printer driver (deb package)" behind a browser EULA
# click-through with no stable direct link. Its "Driver Install Tool" entry
# (linux-brprinter-installer, v2.2.6-0, dlid=dlf006893_000) is Brother's own
# wrapper that downloads and installs the right lpr + cupswrapper deb
# packages for the model you pass it and registers the CUPS queue -- this is
# the officially documented path and what this script drives. Verified
# reachable directly (bypassing the EULA gate) at:
#   https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.6-0.gz
# sha256 at time of download (2026-08-30): matches the installer variable
# below; the check is for download integrity/idempotency, not an
# authenticity signature -- Brother does not publish an official checksum.
#
# This script stops short of the actual install: linux-brprinter-installer
# must run as root and is interactive (EULA agreement, device URI choice),
# and this session has no cached sudo credential and no TTY for sudo to
# prompt on. Run this script yourself in a real terminal:
#   bash scripts/install-brother-dcp-l2665dw.sh
# then, when the installer prompts:
#   - EULA: type Y
#   - device URI list: pick the "(I)" IP option and enter 192.168.0.214
#     (or "(A)" Auto if the script lists an autodetected URI for it)

set -euo pipefail

MODEL="DCP-L2665DW"
PRINTER_IP="192.168.0.214"
INSTALLER="linux-brprinter-installer-2.2.6-0"
INSTALLER_URL="https://download.brother.com/welcome/dlf006893/${INSTALLER}.gz"
EXPECTED_SHA256="7db52d1ca08bc7cab0358b5af860ecc96874a35c799d6f8695ff65072427a8e7"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

# Print os-release field $1 with any quotes removed (empty if unset).
os_release_field() {
	awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2); gsub(/["\047]/, "", v); print v; exit }' \
		"$OS_RELEASE" 2>/dev/null || true
}

os_id="$(os_release_field ID)"
os_id_like="$(os_release_field ID_LIKE)"
case " $os_id $os_id_like " in
*" debian "*) debian_like=1 ;;
*) debian_like=0 ;;
esac
if [ "$debian_like" -ne 1 ] || ! command -v dpkg >/dev/null 2>&1; then
	{
		echo "This script is for Debian/Ubuntu only, and this host doesn't qualify:"
		echo "  $OS_RELEASE: ID=${os_id:-<unset>} ID_LIKE=${os_id_like:-<unset>}; dpkg: $(command -v dpkg || echo 'not found')"
		echo "Brother's installer would fall back to installing rpm packages as root"
		echo "(--nodeps --replacefiles), outside the system package manager."
		echo
		echo "On Arch/CachyOS, use the printer's driverless IPP Everywhere support"
		echo "instead (cups installed and running), as root, e.g. through pkexec:"
		echo "  lpadmin -p $MODEL -E -v ipp://$PRINTER_IP/ipp/print -m everywhere"
		echo "or look in the AUR for a packaged Brother driver for this model."
	} >&2
	exit 1
fi

if ! systemctl is-active --quiet cups; then
	echo "cups.service is not running -- start it before continuing (sudo systemctl start cups)." >&2
	exit 1
fi

# A queue counts as "this printer" if its name contains the model (with or
# without its hyphen) or its device URI carries the printer's IP.
model_bare="${MODEL//-/}"
queue_re="${model_bare}|${MODEL}|${PRINTER_IP//./\\.}"

# Matching "device for NAME: URI" lines, sorted (LC_ALL=C: lpstat's wording
# is localized).
matching_queues() {
	LC_ALL=C lpstat -v 2>/dev/null | grep -iE -e "$queue_re" | sort -u || true
}

# A queue's *configuration* as a non-root user can see it: its device line
# plus the config attributes lpoptions reports -- device-uri and
# printer-make-and-model (the driver/PPD identity). Deliberately NOT
# printer-state-change-time or any other state field: those change on any
# job, idle or offline transition, so including them would report a failed
# reinstall as a successful "update". A reinstall that reconfigures the queue
# changes the URI or the driver; if neither changed, the fingerprint is
# unchanged and the result is "can't verify", not success.
queue_fingerprint() {
	local name="$1"
	LC_ALL=C lpstat -v "$name" 2>/dev/null || true
	LC_ALL=C lpoptions -p "$name" 2>/dev/null |
		grep -oE "(device-uri|printer-make-and-model)=('[^']*'|[^ ]*)" || true
}

queue_names() {
	sed -n 's/^device for \(.*\): [A-Za-z][A-Za-z0-9+.-]*:.*$/\1/p'
}

ask_no() { # ask_no PROMPT -- succeed only on an explicit yes (default no)
	local reply=""
	printf '%s [y/N] ' "$1" >&2
	read -r reply </dev/tty || reply=""
	case "$reply" in
	[yY] | [yY][eE][sS]) return 0 ;;
	esac
	return 1
}

# Snapshot matching queues before touching anything. Brother's installer
# exits 0 even when its package install fails, so an existing queue -- an
# earlier run, or the driverless IPP queue the Arch branch above recommends
# -- would make a failed install look successful.
queues_before="$(matching_queues)"
remove_existing=0
kept_existing=0
declare -A fingerprint_before=()
if [ -n "$queues_before" ]; then
	echo "A CUPS queue for this printer already exists:" >&2
	printf '  %s\n' "$queues_before" >&2
	echo "An existing queue can make a failed Brother install look successful here." >&2
	if ! ask_no "Run the installer anyway?"; then
		echo "Aborted; nothing was changed." >&2
		exit 1
	fi
	echo "Removing the existing queue(s) first lets this script check the install" >&2
	echo "properly (success = a matching queue exists again afterwards)." >&2
	if ask_no "Remove them with lpadmin -x before installing?"; then
		remove_existing=1
	else
		kept_existing=1
		while IFS= read -r name; do
			fingerprint_before[$name]="$(queue_fingerprint "$name")"
		done < <(queue_names <<<"$queues_before")
	fi
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSO "$INSTALLER_URL"
actual_sha256="$(sha256sum "${INSTALLER}.gz" | cut -d' ' -f1)"
if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
	echo "Downloaded file hash does not match the pinned value -- Brother may have" >&2
	echo "updated the installer since this script was written. Re-verify by hand" >&2
	echo "before running it: $workdir/${INSTALLER}.gz (got $actual_sha256)" >&2
	exit 1
fi
gunzip "${INSTALLER}.gz"
chmod +x "$INSTALLER"

if [ "$remove_existing" -eq 1 ]; then
	# Only now, after the installer is downloaded and verified, so a failed
	# download never costs the user their queue.
	while IFS= read -r name; do
		echo "Removing CUPS queue $name"
		sudo lpadmin -x "$name"
	done < <(queue_names <<<"$queues_before")
	queues_before=""
fi

echo "About to run: sudo bash $workdir/$INSTALLER $MODEL"
echo "When prompted for the device URI, choose IP and enter: $PRINTER_IP"
echo
sudo bash "./$INSTALLER" "$MODEL"

# Success: a matching queue that is new (or whose device line changed) since
# the snapshot -- after removing the old ones that just means one exists
# again. When the user kept an existing queue, success needs that queue to
# still be there (still matching) with a changed fingerprint: a queue that
# vanished also "changes" its fingerprint, to nothing, and that is a failure.
echo
echo "--- CUPS queues for the $MODEL ---"
queues_after="$(matching_queues)"
printf '%s\n' "${queues_after:-(none)}"
new_queues="$(comm -13 \
	<(printf '%s\n' "$queues_before" | sed '/^$/d') \
	<(printf '%s\n' "$queues_after" | sed '/^$/d'))"
if [ -n "$new_queues" ]; then
	echo "New or changed queue(s):"
	printf '  %s\n' "$new_queues"
	lpstat -d || true
	exit 0
fi
if [ "$kept_existing" -eq 1 ]; then
	kept_after="$(comm -12 \
		<(queue_names <<<"$queues_before" | sort -u) \
		<(queue_names <<<"$queues_after" | sort -u))"
	if [ -z "$kept_after" ]; then
		echo >&2
		echo "The existing $MODEL queue is gone and no matching queue replaced it, so the install failed." >&2
		echo "Check the installer output above." >&2
		exit 1
	fi
	while IFS= read -r name; do
		if [ "$(queue_fingerprint "$name")" != "${fingerprint_before[$name]-}" ]; then
			echo "The existing queue $name's configuration changed (driver), so the installer did update it."
			lpstat -d || true
			exit 0
		fi
	done <<<"$kept_after"
	echo >&2
	echo "WARNING: success can't be verified. The existing $MODEL queue looks exactly as it did before" >&2
	echo "(same device URI and driver), and CUPS doesn't tell non-root users when a queue" >&2
	echo "was last reconfigured. Check the installer output above, or re-run and let this script" >&2
	echo "remove the queue first so the result can be checked." >&2
	# Distinct status so a caller doesn't read "unverified" as success.
	exit 2
fi
echo >&2
echo "No new or changed CUPS queue for the $MODEL (name $model_bare or URI with $PRINTER_IP) appeared." >&2
echo "The installer probably failed even if it reported nothing; check its output above." >&2
exit 1
