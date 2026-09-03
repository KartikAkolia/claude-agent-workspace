#!/usr/bin/env bash
# install-brother-dcp-l2665dw.sh — install Brother's official Linux CUPS
# driver for the DCP-L2665DW and register it as a CUPS printer queue.
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

if ! systemctl is-active --quiet cups; then
	echo "cups.service is not running -- start it before continuing (sudo systemctl start cups)." >&2
	exit 1
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

echo "About to run: sudo bash $workdir/$INSTALLER $MODEL"
echo "When prompted for the device URI, choose IP and enter: $PRINTER_IP"
echo
sudo bash "./$INSTALLER" "$MODEL"

echo
echo "--- resulting CUPS queues ---"
lpstat -p -d
