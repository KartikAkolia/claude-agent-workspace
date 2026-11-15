# Brother DCP-L2665DW printer driver

`scripts/install-brother-dcp-l2665dw.sh` installs Brother's own Linux CUPS driver for the DCP-L2665DW network printer. It downloads a pinned copy of Brother's `linux-brprinter-installer`, runs it, then checks that a CUPS queue for the printer really exists afterwards, because the installer's own exit status says nothing. It is for Debian and Ubuntu only and refuses every other host. Run it as yourself in a real terminal: its own questions are read from `/dev/tty`, the installer is interactive, and both the installer and any `lpadmin -x` run through `sudo`. No run against the real printer is recorded in this repo, and the 2026-11-14 audit verified its logic with stubs only ([script-audit-2026-11-14.md](script-audit-2026-11-14.md), SYS-2). On the current `asus-vivobook` install it refuses: as checked on 2026-11-15 that host is Arch, with `/usr/bin/rpm` from `rpm-tools`, no `dpkg`, and no `cups` package (only `libcups`), so even the driverless route below needs `cups` installed and started first.

## Why Debian and Ubuntu only

Brother's installer chooses deb or rpm packages by probing for `dpkg` first and then `rpm`. On a host that has `rpm` but no `dpkg`, which includes Arch and CachyOS once `rpm-tools` is installed, it installs Brother's rpm packages as root with `rpm -ihv --nodeps --replacefiles --replacepkgs --ignorearch`, behind pacman's back. Every exit in the installer is `exit 0`, so that path, and any other failure, looks like success to whatever ran it. Both facts were checked in the pinned v2.2.6-0 on 2026-11-15.

So the script exits before changing anything unless `/etc/os-release` has `debian` in `ID` or `ID_LIKE` and `dpkg` is on `PATH`. Setting `OS_RELEASE` to another file overrides `/etc/os-release`, for testing. It also needs `cups.service` running. On a refused host it prints the driverless IPP Everywhere route instead, to run as root (for example through `pkexec`) with CUPS installed and running, or suggests a packaged Brother driver from the AUR:

```bash
lpadmin -p DCP-L2665DW -E -v ipp://<printer-ip>/ipp/print -m everywhere
```

On 2026-08-30 the printer had IPP (631), JetDirect raw (9100) and its embedded web server (80 and 443) open, but `-m everywhere` has never been tried against it.

## The pinned installer

Brother's [support page for this model](https://support.brother.com/g/b/downloadlist.aspx?c=gb&lang=en&prod=dcpl2665dw_eu&os=128) put its "Linux printer driver (deb package)" behind a browser EULA click-through with no stable direct link (2026-08-30). Its "Driver Install Tool" entry, `linux-brprinter-installer` v2.2.6-0 (dlid `dlf006893_000`), is Brother's documented route: given a model name, it downloads the matching lpr and cupswrapper packages, installs them and creates the CUPS queue. The script fetches it from the direct URL in `INSTALLER_URL`, which skips the EULA page, and compares it with `EXPECTED_SHA256`. The URL was still reachable and the hash still matched on 2026-11-15.

Brother publishes no checksum, so the pin proves only that the file is the one first downloaded on 2026-08-30. That gives download integrity and a clear stop when Brother replaces the file. It is not an authenticity check. A mismatch exits before any queue is touched.

The installer downloads the driver packages itself with `wget`. If `wget` is missing it tries `apt-get install wget`, and quits if that fails. If it can't reach Brother's servers, it asks whether to use a proxy.

## Usage

```bash
bash scripts/install-brother-dcp-l2665dw.sh
```

The installer's prompts, in the order v2.2.6-0 asks them:

1. It lists the packages it will download and asks `OK? [y/N]`. Type `y`. The default, no, quits having installed nothing, and the script then reports failure.
2. A licence for each package, `Do you agree? [Y/n]`. Type `Y`.
3. `Will you specify the Device URI? [Y/n]`, if it appears. Type `Y`.
4. A numbered list of the device URIs CUPS found, then `(I)` to specify an IP address and `(A)` Auto with the URI it would use in brackets. Type `I` (or its number) and, at `enter IP address`, give `192.168.0.214`, the printer address the script prints just before starting the installer (`PRINTER_IP`). The queue gets the device URI `lpd://<that address>/BINARY_P1`. Choose `A` only if the bracketed URI is this printer. A bare Enter also picks Auto, which falls back to `usb://dev/usblp0` when nothing was detected.
5. `Test Print? [y/N]`. Optional, and the only check here that a page actually prints.

## Safety and invariants

Before touching anything, the script snapshots every CUPS queue that looks like this printer: any `lpstat -v` line ("device for NAME: URI", read under `LC_ALL=C` because lpstat's wording is localized) containing the model, with or without its hyphen and in any case, or the printer's IP. Because the installer exits 0 even when it fails, a queue left by an earlier run, or the driverless queue above, would otherwise make a failed install look successful. If one exists, the script shows it and asks two questions, both defaulting to no: whether to run the installer at all (answering no exits with nothing changed), and whether to remove the old queue(s) with `lpadmin -x` first, which is what makes the result checkable.

Queues are removed only after the installer has downloaded and passed the hash check, so a failed download never costs a queue.

Afterwards, success is a matching `lpstat -v` line that wasn't there before: a new queue, or an old one whose device URI changed. After a removal that simply means one exists again. If the old queue was kept and nothing new appeared, it must still exist and its configuration fingerprint must have changed. The fingerprint is its `lpstat -v` line plus the `device-uri` and `printer-make-and-model` (the driver) that `lpoptions -p` reports. It deliberately leaves out `printer-state-change-time` and every other state field: those change on any job, idle or offline transition, and would report a failed reinstall as an update. A kept queue that vanished is a failure, not a change.

On a host with AppArmor's `aa-complain` installed, the installer runs `aa-complain cupsd` without asking, which puts CUPS's AppArmor profile into complain mode.

## Exit status

- `0`: a matching queue is new, or an existing one's device URI or driver changed.
- `1`: failed. The host isn't Debian-family with `dpkg`, `cups.service` isn't running, you declined to run the installer over an existing queue, the hash didn't match, no new or changed queue appeared, or the kept queue disappeared.
- `2`: unverified. The kept queue looks exactly as before (same URI and driver), and CUPS doesn't tell non-root users when a queue was last reconfigured, so the script can't tell whether the reinstall did anything. Re-run and let it remove the queue first to get a checkable result.

Any other status comes from a command that failed under `set -e`, for example curl's own exit code when the download fails.

## Known gaps

Success means only that a matching queue exists. The script doesn't check that the device URI reaches the printer or that a page prints, and a queue whose name carries the model counts whatever its URI, including Auto's `usb://dev/usblp0` fallback. Use the installer's test print, or `lp -d <queue> <file>`, to confirm.

The `(I)` route prints over LPD (port 515). The 2026-08-30 check recorded 631, 9100, 80 and 443 open and said nothing about 515. If jobs stall, the queue can be pointed at JetDirect instead with `sudo lpadmin -p <queue> -v socket://<printer-ip>:9100`.

The printer's address is fixed in `PRINTER_IP`. It drives both the queue matching and the printed hints, so edit it if the printer's address changes.

On a hash mismatch the error names the downloaded file in the script's temporary directory, but the `EXIT` trap deletes that directory as the script exits, so the file is already gone. Download `INSTALLER_URL` again by hand to inspect it.
