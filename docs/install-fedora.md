<!-- coderabbit-ai-generated:v1 -->

# Fedora and EL10 post-install setup

`scripts/install-fedora.sh` supports conventional DNF-based Fedora and Rocky, AlmaLinux, CentOS Stream and RHEL 10. Atomic/rpm-ostree systems are rejected. It changes the host, so first inspect its help and dry-run output.

## Usage

```bash
bash scripts/install-fedora.sh --help
sudo bash scripts/install-fedora.sh --dry-run --user "$USER"
sudo bash scripts/install-fedora.sh --user "$USER"
```

Defaults retain the original requested setup: CachyOS kernel, SELinux disabled, firewalld stopped and masked, build tools, Java 25, CLI tools, fstrim and applicable VM tools. Use the documented flags to opt out. No reboot is performed automatically.

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:b2ef96a4cec494ab4cd50aecc8f6680cd689b38dd45dc709979bbf6f0190c2b7 -->

Before making changes, preflight checks required commands. Python 3 is required for atomic configuration edits; fallback downloads require curl, tar and sha256sum; user operations require runuser and setpriv. RHEL additionally needs subscription-manager and valid repository access. Missing prerequisites stop the script with a specific message. When a compatible CachyOS kernel needs installation or header repair, preflight also checks the matching COPR repository metadata over HTTPS before changing hostname or configuration. A missing or unreachable repository stops setup. Complete kernel installations avoid this network dependency on reruns.

<!-- /coderabbit-ai-generated:v1 -->

## Mandatory control-flow rule

Never nest `if` statements in this installer, its generated Bash block or its embedded Python editors. Use guard clauses and small named helpers. `python3 scripts/test_install_fedora.py` checks shell syntax trees and embedded Python syntax trees. The Bash CI workflow runs this gate with the pinned shfmt version. The gate must stay enabled when changing the installer.

## Preserved state and failure behavior

The script edits only its delimited `.bashrc` block. Content outside that block is retained, including existing tool initialization lines. Those lines may initialize a tool twice if a manual setup already exists; inspect them yourself before removing any. Reversed, nested and unmatched markers cause an error without rewriting the file. Symlinks and files not owned by the target user are rejected.

Both `.bashrc` and `dnf.conf` use a temporary file in the destination directory, synchronize the file, preserve existing metadata, check for concurrent content changes, then replace atomically and synchronize the directory. The first existing original is backed up with `.bak.install-fedora`. Catchable termination cleans temporary files; SIGKILL or power loss can leave a harmless temporary file. <!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:679ae27099eb2df384471341d8e1aa3829f790606bc5171b1983f85a9a988d73 -->

No transaction rollback across package installations is promised. Before host changes, the installer checks RPM dependencies and duplicates under its lock. An interrupted DNF upgrade can leave duplicate system packages; setup then stops with recovery guidance. Review and repair that package-manager state before rerunning. DNF4 provides `dnf remove --duplicates`; DNF5 support depends on its version, so check `dnf remove --help` first. Review the proposed transaction before accepting recovery. The health gate excludes obsoletes checks because the current COPR metapackage has a self-matching legacy Provide that triggers a DNF4 self-obsoletes warning; dependency and duplicate checks still run.

<!-- /coderabbit-ai-generated:v1 --> Concurrent script runs are rejected using flock.

Only the `[main]` DNF section is tuned; per-repository overrides remain intact. CentOS Stream and RHEL bootstrap EPEL using its official release RPM URL. DNF4 and DNF5 use their corresponding plugins and configuration commands.

CachyOS LTS and Server require x86-64-v2; CachyOS and RT require v3. CPUs below v2 retain the stock kernel. A v2 CPU requesting CachyOS or RT receives LTS. Secure Boot enabled or unknown prevents unsigned kernel installation. <!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:adf11fd1ade39507fd5833a04c4dc11e891145529e54881eeb97255d3270fea5 -->

An existing kernel installation has its matching development package repaired on reruns, while its boot default is preserved to respect deliberate rollback. Missing initramfs files or boot entries after an interrupted RPM transaction are regenerated with kernel-install. Recovery preserves the existing default; inspect it and explicitly select the CachyOS kernel if desired.

<!-- /coderabbit-ai-generated:v1 -->

Target accounts resolving to UID zero are rejected. User commands have a clean environment and inherit `no_new_privs`, preventing sudo/setuid elevation. Fallback installer scripts use versioned URLs and SHA-256 checks. Starship's release is pinned too; the pinned Zoxide installer still resolves its latest upstream binary. Downloads remain dependent on trusted upstream HTTPS services. Tools are checked in the target user's PATH.

Exit status 0 means processing completed, 2 means requested packages remain incomplete, and other nonzero statuses indicate fatal errors or signals. The EXIT handler prints completed work and known reboot requirements after failures and catchable interruption. Reboot requirements configured before a prior run are detected from current SELinux state. SIGKILL cannot print a summary.

`--dry-run` avoids DNF repository queries and all writes. Repository availability is unresolved in this mode, so a CLI-tool download can be shown even if a normal run would select a distribution package. `OS_RELEASE_FILE` can override OS detection only during dry runs.

## Validation

Run the focused checks from the repository root with the versions in `.lint-versions`:

```bash
./lint-bash.sh scripts/install-fedora.sh
./lint-python.sh scripts/test_install_fedora.py
python3 scripts/test_install_fedora.py
./validate-config.sh .github/workflows/lint-bash.yml
```

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:6d5a8f41386f8f41cd1a4a9b33c50b6352eea555362ee8bc5f92d8fadf103cca -->

The regression suite uses synthetic files and mocked package and boot commands. It does not install packages or change host configuration. Full package, service and reboot verification requires disposable Fedora and EL10 VMs. Keep their disk overlays, SSH keys and logs outside the repository. Exercise the default installation, rerun it, interrupt a run, rerun after the interruption, and reboot to check `uname -r`, `getenforce`, `grubby --default-kernel` and service state. Include CPUs below v2 and UEFI Secure Boot in additional platform coverage. The current sandbox runtime matrix uses Fedora Cloud 43 and CentOS Stream 10; other releases and distributions need separate verification. Under QEMU TCG, the supported guest setting `HARDLINK=no` in `/etc/sysconfig/kernel` avoids slow optional kernel-header deduplication. <!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:63e18e5f696b8302f65660a974c0a2a1ef7820f18ecff215328aab3f312a6b47 -->

This is a disposable test-fixture setting; the installer does not change it. Additional pristine default-install fixtures set `hostonly="yes"` in `/etc/dracut.conf.d/99-audit-hostonly.conf` to reduce generic-driver image generation. The original recovery fixtures retain generic initramfs generation. Both configurations require real boot checks.

<!-- /coderabbit-ai-generated:v1 --> Guests making outbound HTTPS downloads must trust the sandbox public proxy CA when applicable; keep TLS verification enabled.

<!-- /coderabbit-ai-generated:v1 -->
