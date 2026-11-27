#!/usr/bin/env bash
# install-brother-dcp-l2665dw.sh: install Brother's CUPS driver for the DCP-L2665DW via its pinned
# linux-brprinter-installer (Debian/Ubuntu only). Run it in a terminal; at the prompts accept the
# EULA and choose the IP URI. Exit 0 queue verified, 1 failed, 2 kept queue unverifiable.
# Docs: docs/brother-dcp-l2665dw-printer.md

set -Eeuo pipefail
# Any unhandled failure exits 1, as the header promises, not with the failing command's own status.
trap 'exit 1' ERR

MODEL="DCP-L2665DW"
PRINTER_IP="192.168.0.214"
INSTALLER="linux-brprinter-installer-2.2.6-0"
INSTALLER_URL="https://download.brother.com/welcome/dlf006893/${INSTALLER}.gz"
EXPECTED_SHA256="7db52d1ca08bc7cab0358b5af860ecc96874a35c799d6f8695ff65072427a8e7"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

fail() {
	printf '%s\n' "$@" >&2
	exit 1
}

os_release_field() {
	awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2); gsub(/["\047]/, "", v); print v; exit }' \
		"$OS_RELEASE" 2>/dev/null || true
}

os_id="$(os_release_field ID)"
os_id_like="$(os_release_field ID_LIKE)"
{ [[ " $os_id $os_id_like " == *" debian "* ]] && command -v dpkg >/dev/null 2>&1; } ||
	fail "This script is for Debian/Ubuntu only, and this host doesn't qualify:" \
		"  $OS_RELEASE: ID=${os_id:-<unset>} ID_LIKE=${os_id_like:-<unset>}; dpkg: $(command -v dpkg || echo 'not found')" \
		"Brother's installer would fall back to installing rpm packages as root" \
		"(--nodeps --replacefiles), outside the system package manager." \
		"" \
		"On Arch/CachyOS, use the printer's driverless IPP Everywhere support" \
		"instead (cups installed and running), as root, e.g. through pkexec:" \
		"  lpadmin -p $MODEL -E -v ipp://$PRINTER_IP/ipp/print -m everywhere" \
		"or look in the AUR for a packaged Brother driver for this model."
systemctl is-active --quiet cups ||
	fail "cups.service is not running -- start it before continuing (sudo systemctl start cups)."

model_bare="${MODEL//-/}"
queue_re="${model_bare}|${MODEL}|${PRINTER_IP//./\\.}"

matching_queues() {
	LC_ALL=C lpstat -v 2>/dev/null | grep -iE -e "$queue_re" | sort -u || true
}

# Config only (device URI, driver), never state fields: those change on any job and would fake an update.
queue_fingerprint() {
	local name="$1"
	LC_ALL=C lpstat -v "$name" 2>/dev/null || true
	LC_ALL=C lpoptions -p "$name" 2>/dev/null |
		grep -oE "(device-uri|printer-make-and-model)=('[^']*'|[^ ]*)" || true
}

queue_names() {
	sed -n 's/^device for \(.*\): [A-Za-z][A-Za-z0-9+.-]*:.*$/\1/p'
}

ask_no() {
	local reply=""
	printf '%s [y/N] ' "$1" >&2
	read -r reply </dev/tty || reply=""
	[[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

queues_before="$(matching_queues)"
remove_existing=0
kept_existing=0
declare -A fingerprint_before=()
if [ -n "$queues_before" ]; then
	echo "A CUPS queue for this printer already exists:" >&2
	printf '  %s\n' "$queues_before" >&2
	echo "An existing queue can make a failed Brother install look successful here." >&2
	ask_no "Run the installer anyway?" || fail "Aborted; nothing was changed."
	echo "Removing the existing queue(s) first lets this script check the install" >&2
	echo "properly (success = a matching queue exists again afterwards)." >&2
	ask_no "Remove them with lpadmin -x before installing?" && remove_existing=1
	[ "$remove_existing" -eq 1 ] || kept_existing=1
fi
if [ "$kept_existing" -eq 1 ]; then
	while IFS= read -r name; do
		fingerprint_before[$name]="$(queue_fingerprint "$name")"
	done < <(queue_names <<<"$queues_before")
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSO "$INSTALLER_URL"
actual_sha256="$(sha256sum "${INSTALLER}.gz" | cut -d' ' -f1)"
[ "$actual_sha256" = "$EXPECTED_SHA256" ] || {
	trap - EXIT
	fail "Downloaded file hash does not match the pinned value -- Brother may have" \
		"updated the installer since this script was written. The download is kept for checking" \
		"by hand: $workdir/${INSTALLER}.gz (sha256 $actual_sha256, pinned $EXPECTED_SHA256);" \
		"delete $workdir when done."
}
gunzip "${INSTALLER}.gz"
chmod +x "$INSTALLER"

# Remove queues only after the download is verified, so a failed download never costs one.
if [ "$remove_existing" -eq 1 ]; then
	while IFS= read -r name; do
		echo "Removing CUPS queue $name"
		sudo lpadmin -x "$name"
	done < <(queue_names <<<"$queues_before")
	queues_before=""
fi

echo "About to run: sudo bash $workdir/$INSTALLER $MODEL"
echo "When prompted for the device URI, choose IP and enter: $PRINTER_IP"
# The installer's own test runs as root, whose PATH has the sbin directories a user's may lack.
if { command -v aa-complain || [ -x /usr/sbin/aa-complain ] || [ -x /sbin/aa-complain ]; } >/dev/null 2>&1; then
	echo "The installer will also run 'aa-complain cupsd', putting CUPS's AppArmor profile in complain mode."
	echo "Check: sudo grep cupsd /sys/kernel/security/apparmor/profiles; revert: sudo aa-enforce cupsd"
fi
echo
sudo bash "./$INSTALLER" "$MODEL"

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
[ "$kept_existing" -eq 1 ] ||
	fail "" "No new or changed CUPS queue for the $MODEL (name $model_bare or URI with $PRINTER_IP) appeared." \
		"The installer probably failed even if it reported nothing; check its output above."
kept_after="$(comm -12 \
	<(queue_names <<<"$queues_before" | sort -u) \
	<(queue_names <<<"$queues_after" | sort -u))"
[ -n "$kept_after" ] ||
	fail "" "The existing $MODEL queue is gone and no matching queue replaced it, so the install failed." \
		"Check the installer output above."
while IFS= read -r name; do
	[ "$(queue_fingerprint "$name")" != "${fingerprint_before[$name]-}" ] || continue
	echo "The existing queue $name's configuration changed (driver), so the installer did update it."
	lpstat -d || true
	exit 0
done <<<"$kept_after"
printf '%s\n' "" \
	"WARNING: success can't be verified. The existing $MODEL queue looks exactly as it did before" \
	"(same device URI and driver), and CUPS doesn't tell non-root users when a queue" \
	"was last reconfigured. Check the installer output above, or re-run and let this script" \
	"remove the queue first so the result can be checked." >&2
exit 2
