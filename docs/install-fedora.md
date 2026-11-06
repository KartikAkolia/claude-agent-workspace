# Fedora and EL10 post-install setup

`scripts/install-fedora.sh` sets up a fresh DNF-based Fedora or Rocky,
AlmaLinux, CentOS Stream or RHEL 10 machine, VM or bare metal. It replicates
the `rocky10` VM setup from 2026-11-06. Atomic/rpm-ostree systems are
rejected. It changes the host, so read `--help` and a dry run first.

## Usage

```bash
bash scripts/install-fedora.sh --help
sudo bash scripts/install-fedora.sh --dry-run --user "$USER"
sudo bash scripts/install-fedora.sh --user "$USER"
```

By default it installs the CachyOS kernel, disables SELinux, stops and masks
firewalld, and installs the build toolchain, OpenJDK 25, fzf, zoxide,
starship, fstrim and the matching VM guest agent. Each default has an opt-out
flag; Cockpit removal is opt-in (`--remove-cockpit`). It never reboots by
itself.

Exit status 0 means every step finished, 2 means some requested packages
didn't install, and anything else is a fatal error or a signal. The summary,
including any pending reboot, still prints after a failure or Ctrl-C, but not
after SIGKILL. Output is appended to `/var/log/install-fedora.log`.

## Mandatory control-flow rule

Never nest `if` statements in this script, the Bash block it writes into
`~/.bashrc`, or its embedded Python editors. Use guard clauses and small named
helpers instead. `python3 scripts/test_install_fedora.py` enforces this: it
parses the shell with `shfmt -tojson` and the embedded Python with `ast`, and
the Bash CI workflow runs it, so a nested `if` fails CI. Keep the gate enabled
when changing the installer.

## Before it changes anything

Preflight checks for the commands each enabled step needs and stops with a
specific message if one is missing: `dnf`, `rpm`, `python3`, `systemctl` and
`flock` always; `grubby`, `getenforce` and `setenforce` to disable SELinux;
`runuser`, `setpriv`, `curl`, `sha256sum` and `tar` for the CLI tools;
`grubby` and `kernel-install` for the kernel; `subscription-manager` on RHEL.
When the CachyOS kernel or its `-devel-matched` package still needs
installing, preflight also confirms the COPR repository answers over HTTPS
before touching the hostname or any config.

A lock on `/run/install-fedora.lock` rejects a second concurrent run. Next,
`dnf check --dependencies --duplicates` must pass. Any existing RPM dependency
or duplicate problem, even in an unrelated package, stops the run, typically
after an interrupted DNF upgrade. Repair it first: DNF4 has
`dnf remove --duplicates`; on DNF5 check `dnf remove --help`. Review the
proposed transaction before accepting it. The check skips obsoletes because
the COPR metapackage has a self-matching legacy Provide that DNF4 reports as a
self-obsolete.

## What it preserves

The script edits only its own delimited block in `~/.bashrc`, and only as the
target user. Everything outside the block is kept, including tool
initialization lines from a manual setup, which then run twice; remove those
by hand if you want. Reversed, nested or unmatched markers, symlinks, and
files the user doesn't own make it stop without rewriting anything.

Only the `[main]` section of `/etc/dnf/dnf.conf` is tuned; per-repository
settings stay. Both files are written to a temporary file in the same
directory, synced, given the original's metadata, checked for concurrent
changes, then swapped in atomically. The first original is kept as
`*.bak.install-fedora`. A power cut or SIGKILL can leave a stray
`.install-fedora-*` temporary file, which is safe to delete.

Package installs aren't rolled back as a transaction.

## Kernel

CachyOS LTS and Server need an x86-64-v2 CPU; CachyOS and RT need v3. A v2 CPU
asking for CachyOS or RT gets LTS, and a CPU below v2 keeps the stock kernel.
If Secure Boot is enabled or its state can't be read, the unsigned COPR kernel
is skipped.

A freshly installed CachyOS kernel becomes the boot default. On reruns the
current default is left alone, so a deliberate `grubby --set-default` rollback
to the stock kernel sticks. A missing `-devel-matched` package is installed
on rerun. If an interrupted RPM transaction left the kernel without its
initramfs or boot entry, the script regenerates them with `kernel-install`
and keeps the existing default; select the CachyOS kernel yourself afterwards
if you want it.

A reboot still pending from an earlier run is detected from the current boot
default and SELinux state, and reported in the summary.

## Downloads and the target user

The target user comes from `--user` or `$SUDO_USER`; accounts with UID 0 are
rejected. Commands run as that user with a clean environment and
`no_new_privs`, so they can't escalate through sudo or setuid binaries.

zoxide (EL only; Fedora packages it) and starship (packaged nowhere) come
from upstream install scripts pinned to a version and checked against a
SHA-256 before they run. Updating either means changing its URL and checksum
in the script. The pinned zoxide installer still downloads the latest zoxide
binary. Both depend on trusting the upstream HTTPS services.

`--dry-run` makes no writes and no DNF repository queries, so it can't tell
whether a distro package exists. It may show an upstream download where a real
run would use `dnf`. `OS_RELEASE_FILE` overrides OS detection, but only
together with `--dry-run`.

## Validation

Run these from the repository root with the linter versions in
`.lint-versions`:

```bash
./lint-bash.sh scripts/install-fedora.sh
./lint-python.sh scripts/test_install_fedora.py
python3 scripts/test_install_fedora.py
./validate-config.sh .github/workflows/lint-bash.yml
```

The regression suite uses synthetic files and mocked package and boot
commands; it installs nothing and changes no host config. Package, service
and reboot behaviour still needs a disposable Fedora and EL10 VM: run the
default install, rerun it, interrupt a run and rerun, then reboot and check
`uname -r`, `getenforce`, `sudo grubby --default-kernel` and service state.
CPUs below x86-64-v2 and Secure Boot machines need separate coverage. As of
2026-11-06 no real run on EL10 or Fedora has been recorded.
