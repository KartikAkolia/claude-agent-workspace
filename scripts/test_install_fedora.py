#!/usr/bin/env python3
"""Installer regressions. No root, package installation, or host changes required.

Mandatory style gate: no nested shell if statements, including generated shell
blocks. Run with shfmt on PATH: python3 scripts/test_install_fedora.py.
"""

import ast
import json
import os
import re
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("install-fedora.sh").resolve()
BEGIN = "# >>> install-fedora.sh >>>\n"
END = "# <<< install-fedora.sh <<<\n"


def shfmt_json(source):
    result = subprocess.run(
        ["shfmt", "-tojson"],
        input=source,
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


WRAPPERS = {"as_user", "run", "command", "exec", "env"}


def python_commands(node):
    """Yields the arguments of every python3 command, after any wrapper words."""
    if isinstance(node, list):
        for item in node:
            yield from python_commands(item)
        return
    if not isinstance(node, dict):
        return
    if node.get("Type") == "CallExpr":
        words = [
            "".join(part.get("Value", "?") for part in arg.get("Parts", []))
            for arg in node.get("Args", [])
        ]
        while words and (
            words[0] in WRAPPERS or words[0].startswith("-") or "=" in words[0]
        ):
            words = words[1:]
        if words and re.fullmatch(r"(.*/)?python3(\.\d+)?", words[0]):
            yield words[1:]
    for value in node.values():
        yield from python_commands(value)


def write_os_release(directory, os_id, version):
    path = Path(directory) / "os-release"
    path.write_text(
        f'ID={os_id}\nVERSION_ID={version}\nPRETTY_NAME="{os_id} {version}"\n'
    )
    return str(path)


def wait_for_text(path, text, timeout=10):
    deadline = time.monotonic() + timeout
    while text not in path.read_text() and time.monotonic() < deadline:
        time.sleep(0.05)
    return text in path.read_text()


# Stubs for test_whole_dry_run_changes_nothing: read-only queries answer, and
# anything that would change the host is recorded in $FIXTURE/forbidden.
DRY_RUN_STUBS = r"""
forbid() { printf '%s\n' "$*" >>"$FIXTURE/forbidden"; return 99; }
for cmd in dnf python3 setenforce setsebool kernel-install runuser setpriv curl \
	flock subscription-manager tee mkdir cp mv rm ln chmod chown touch; do
	eval "$cmd() { forbid $cmd \"\$@\"; }"
done
grubby() {
	case "$1" in
	--default-kernel) echo /boot/vmlinuz-stock ;;
	--info=ALL) echo 'args="quiet"' ;;
	*) forbid grubby "$@" ;;
	esac
}
systemctl() {
	case "$1" in
	list-unit-files) echo "firewalld.service enabled enabled" ;;
	is-enabled) echo enabled ;;
	is-active) return 0 ;;
	*) forbid systemctl "$@" ;;
	esac
}
rpm() {
	case "$1" in
	-q) return 1 ;;
	-qa) echo cockpit-ws ;;
	*) forbid rpm "$@" ;;
	esac
}
sed() {
	case " $* " in
	*" -i "*) forbid sed "$@" ;;
	*) command sed "$@" ;;
	esac
}
hostnamectl() {
	case "$1" in
	--static) echo old-host ;;
	*) forbid hostnamectl "$@" ;;
	esac
}
getent() { echo "audit:x:1000:1000::$FIXTURE:/bin/bash"; }
uname() { case "$1" in -m) echo x86_64 ;; *) echo 6.12.0-55.el10.x86_64 ;; esac; }
systemd-detect-virt() { echo kvm; }
secure_boot_state() { echo disabled; }
cpu_supports_level() { return 0; }
getenforce() { echo Enforcing; }
selinuxenabled() { return 0; }
getsebool() { echo 'domain_kernel_load_modules --> off'; }
"""


def shell(code, *, env=None, cwd=None):
    return subprocess.run(
        ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n{code}"],
        text=True,
        capture_output=True,
        env=os.environ | (env or {}),
        cwd=cwd,
        check=False,
    )


class InstallerTests(unittest.TestCase):
    def ok(self, code, **kwargs):
        result = shell(code, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_cpu_matrix(self):
        for level in (1, 2, 3):
            for variant in ("cachyos", "rt", "lts", "server"):
                expected = variant
                if level == 1:
                    expected = "none"
                if level == 2 and variant in ("cachyos", "rt"):
                    expected = "lts"
                with self.subTest(level=level, variant=variant):
                    result = self.ok(
                        f"KERNEL_VARIANT={variant}; "
                        f"cpu_supports_level() {{ (($1 <= {level})); }}; "
                        'select_kernel_variant; echo "$KERNEL_VARIANT"'
                    )
                    self.assertEqual(result.stdout.strip(), expected)

    def test_uid_zero_rejected_including_alias(self):
        for user in ("root", "alias"):
            result = shell(
                f"TARGET_USER={user}; "
                "getent() { echo 'root:x:0:0:root:/root:/bin/bash'; }; "
                "detect_target_user"
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("UID 0", result.stderr)

    def edit_rc(self, home):
        return shell(
            'as_user() { "$@"; }; TARGET_HOME="$FIXTURE"; write_bashrc_block',
            env={"FIXTURE": str(home)},
        )

    def test_bashrc_malformed_markers_preserved(self):
        fixtures = [
            BEGIN + "tail\n",
            END + "middle\n" + BEGIN + "tail\n",
            BEGIN + END + "middle\n" + BEGIN + "tail\n",
            BEGIN + BEGIN + END,
            END,
        ]
        for fixture in fixtures:
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as td:
                rc = Path(td) / ".bashrc"
                original = ("prefix\n" + fixture).encode()
                rc.write_bytes(original)
                result = self.edit_rc(td)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(rc.read_bytes(), original)
                self.assertFalse(Path(str(rc) + ".bak.install-fedora").exists())

    def test_bashrc_preservation_and_rerun(self):
        with tempfile.TemporaryDirectory() as td:
            rc = Path(td) / ".bashrc"
            before = b'  # user comment\n\neval "$(zoxide init bash --cmd j)"\n'
            after = b"\n# user tail\n"
            rc.write_bytes(before + BEGIN.encode() + b"old\n" + END.encode() + after)
            rc.chmod(0o640)
            os.utime(rc, (1_000_000_000, 1_000_000_000))
            self.assertEqual(self.edit_rc(td).returncode, 0)
            first = rc.read_bytes()
            self.assertGreater(rc.stat().st_mtime, 1_000_000_000 + 86400)
            self.assertTrue(first.startswith(before + after))
            self.assertEqual(first.count(BEGIN.encode()), 1)
            self.assertEqual(rc.stat().st_mode & 0o777, 0o640)
            backup = Path(str(rc) + ".bak.install-fedora").read_bytes()
            self.assertEqual(self.edit_rc(td).returncode, 0)
            self.assertEqual(rc.read_bytes(), first)
            self.assertEqual(Path(str(rc) + ".bak.install-fedora").read_bytes(), backup)

    def test_bashrc_symlink_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "target"
            target.write_text("untouched\n")
            (Path(td) / ".bashrc").symlink_to(target)
            self.assertNotEqual(self.edit_rc(td).returncode, 0)
            self.assertEqual(target.read_text(), "untouched\n")

    def test_bashrc_new_home(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(self.edit_rc(td).returncode, 0)
            result = subprocess.run(
                ["bash", "-n", str(Path(td) / ".bashrc")], check=False
            )
            self.assertEqual(result.returncode, 0)

    def test_dnf_only_main_and_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            conf = Path(td) / "dnf.conf"
            original = b"# preamble\n[custom]\nfastestmirror=False\n[main]\n  defaultyes=False\nkeep=True\n[other]\nmax_parallel_downloads=2\n"
            conf.write_bytes(original)
            conf.chmod(0o640)
            os.utime(conf, (1_000_000_000, 1_000_000_000))
            code = 'update_dnf_conf "$FIXTURE"'
            self.ok(code, env={"FIXTURE": str(conf)})
            first = conf.read_bytes()
            # The edit gets a fresh mtime; the one-time backup keeps the
            # original's (P4-7: copystat used to backdate the edit).
            self.assertGreater(conf.stat().st_mtime, 1_000_000_000 + 86400)
            self.assertEqual(
                Path(str(conf) + ".bak.install-fedora").stat().st_mtime,
                1_000_000_000,
            )
            self.assertIn(b"[custom]\nfastestmirror=False", first)
            self.assertIn(b"[other]\nmax_parallel_downloads=2", first)
            self.assertNotIn(b"defaultyes=False", first)
            self.assertIn(b"keep=True", first)
            self.assertEqual(conf.stat().st_mode & 0o777, 0o640)
            # An unchanged file gets the distinct EDITOR_UNCHANGED status.
            rerun = shell(code, env={"FIXTURE": str(conf)})
            self.assertEqual(rerun.returncode, 3, rerun.stderr)
            self.assertEqual(conf.read_bytes(), first)
            self.assertEqual(
                Path(str(conf) + ".bak.install-fedora").read_bytes(), original
            )

    def test_dnf_missing_main(self):
        with tempfile.TemporaryDirectory() as td:
            conf = Path(td) / "dnf.conf"
            conf.write_text("[custom]\nfastestmirror=False\n")
            self.ok('update_dnf_conf "$FIXTURE"', env={"FIXTURE": str(conf)})
            self.assertTrue(conf.read_text().startswith("[main]\n"))
            self.assertIn("[custom]\nfastestmirror=False", conf.read_text())

    def test_editors_ignore_planted_modules(self):
        # Without -I, `python3 -` puts the cwd (and PYTHONPATH) first on sys.path,
        # so a shutil.py in the directory sudo ran from would execute as root.
        with tempfile.TemporaryDirectory() as td:
            planted = Path(td) / "planted"
            planted.mkdir()
            marker = Path(td) / "imported"
            # The editors' direct non-builtin imports; -I keeps the whole
            # directory off sys.path, so transitive imports are covered too.
            for name in ("pathlib", "re", "shutil", "signal", "tempfile"):
                (planted / f"{name}.py").write_text(
                    f"open({str(marker)!r}, 'w').write({name!r})\n"
                    "raise SystemExit(77)\n"
                )
            control = subprocess.run(
                ["python3", "-"],
                input="import shutil\n",
                text=True,
                cwd=planted,
                env={k: v for k, v in os.environ.items() if k != "PYTHONSAFEPATH"},
                capture_output=True,
                check=False,
            )
            self.assertEqual(control.returncode, 77, "planted module not reachable")
            marker.unlink()
            conf = Path(td) / "dnf.conf"
            conf.write_text("[main]\n")
            env = {"FIXTURE": td, "PYTHONPATH": str(planted)}
            self.ok('update_dnf_conf "$FIXTURE/dnf.conf"', env=env, cwd=planted)
            self.ok(
                'as_user() { "$@"; }; TARGET_HOME="$FIXTURE"; write_bashrc_block',
                env=env,
                cwd=planted,
            )
            self.assertFalse(marker.exists())
            self.assertIn("max_parallel_downloads=10", conf.read_text())
            self.assertIn(BEGIN, (Path(td) / ".bashrc").read_text())

    def test_every_python_command_is_isolated(self):
        sample = (
            "python3 - x <<'P'\nP\nas_user python3 -I - y\nrequire_commands python3\n"
            "command /usr/bin/python3 -c z\nenv -i LC_ALL=C python3.12 -\n"
        )
        self.assertEqual(
            list(python_commands(shfmt_json(sample))),
            [["-", "x"], ["-I", "-", "y"], ["-c", "z"], ["-"]],
        )
        commands = list(python_commands(shfmt_json(SCRIPT.read_text())))
        self.assertGreaterEqual(len(commands), 2)
        for args in commands:
            self.assertEqual(args[:1], ["-I"], f"python3 without -I: {args}")

    def test_dnf_conf_noted_only_when_changed(self):
        for status, noted in ((0, True), (3, False)):
            with self.subTest(status=status):
                result = self.ok(
                    f"update_dnf_conf() {{ return {status}; }}; step_dnf_conf; "
                    'printf "%s\\n" "${SUMMARY[@]}"'
                )
                self.assertEqual("dnf.conf tuned" in result.stdout, noted)
        result = shell(
            "update_dnf_conf() { return 143; }; step_dnf_conf; echo FORBIDDEN"
        )
        self.assertEqual(result.returncode, 143)
        self.assertNotIn("FORBIDDEN", result.stdout)

    def test_lts_fallback_is_noted(self):
        result = self.ok(
            "KERNEL_VARIANT=rt; cpu_supports_level() { (($1 <= 2)); }; "
            'select_kernel_variant; printf "%s\\n" "${SUMMARY[@]}"'
        )
        self.assertIn("CachyOS rt needs an x86-64-v3 CPU; using the LTS", result.stdout)

    def test_rerun_reports_kernel_that_is_not_default(self):
        # After an interrupted first run the stock kernel can still be the default.
        image = "/boot/vmlinuz-7.3.1-1.cachyos1.el10.x86_64"
        for default, reported in (("/boot/vmlinuz-stock", True), (image, False)):
            with self.subTest(default=default):
                result = self.ok(
                    "KERNEL_VARIANT=cachyos; uname() { echo x86_64; }; "
                    "secure_boot_state() { echo disabled; }; "
                    "cpu_supports_level() { return 0; }; "
                    'pkg_installed() { [[ "$1" != *-devel-matched ]]; }; '
                    "ensure_kernel_boot_files() { :; }; "
                    f"kernel_boot_image() {{ echo {image}; }}; "
                    f"grubby() {{ echo {default}; }}; "
                    'run() { echo "RUN $*"; }; step_kernel; '
                    'printf "%s\\n" "${SUMMARY[@]}"'
                )
                # Only install_kernel_packages restoring the existing default.
                self.assertEqual(
                    set(re.findall(r"RUN grubby --set-default (\S+)", result.stdout)),
                    {default},
                )
                self.assertEqual(
                    f"not the boot default; to use it: grubby --set-default {image}"
                    in result.stdout,
                    reported,
                )

    def test_group_signal_keeps_logged_summary(self):
        # A dropped SSH session or a timeout signals the whole process group,
        # tee included, unlike test_failure_and_signal_preserve_summary.
        code = (
            f"source {shlex.quote(str(SCRIPT))}\n"
            'start_log "$LOG"; SUMMARY_READY=1; note "already completed"; '
            "trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; "
            "echo READY; sleep 30"
        )
        for sig in (signal.SIGHUP, signal.SIGTERM):
            with self.subTest(signal=sig.name), tempfile.TemporaryDirectory() as td:
                log, terminal = Path(td) / "log", Path(td) / "terminal"
                log.touch()
                with terminal.open("w") as out:
                    proc = subprocess.Popen(
                        ["bash", "-c", code],
                        env=os.environ | {"LOG": str(log)},
                        stdout=out,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                    try:
                        self.assertTrue(wait_for_text(log, "READY"))
                        os.killpg(proc.pid, sig)
                        proc.wait(timeout=10)
                    finally:
                        try:
                            os.killpg(proc.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                for path in (log, terminal):
                    self.assertTrue(
                        wait_for_text(path, "already completed"),
                        f"{path.name}: {path.read_text()!r}",
                    )

    def test_user_commands_do_not_inherit_run_lock(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.ok(
                'acquire_lock "$FIXTURE/lock"; '
                # Control: children normally inherit the lock fd.
                "sh -c '[ -e /proc/self/fd/9 ]'; "
                "runuser() { sh -c '[ ! -e /proc/self/fd/9 ]'; }; "
                "TARGET_USER=audit; TARGET_HOME=/home/audit; as_user true; "
                '! (acquire_lock "$FIXTURE/lock")',
                env={"FIXTURE": td},
            )
            self.assertIn("another install-fedora run is active", result.stderr)

    def test_missing_flock_is_reported_as_missing(self):
        # P5-5: acquire_lock runs before preflight's require_commands, so it
        # must name a missing flock rather than claim another run is active.
        with tempfile.TemporaryDirectory() as td:
            result = shell(
                'have() { [[ "$1" != flock ]]; }; acquire_lock "$FIXTURE/lock"',
                env={"FIXTURE": td},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required command missing: flock", result.stderr)
            self.assertNotIn("another install-fedora run is active", result.stderr)

    def test_log_tee_does_not_hold_run_lock(self):
        # CR2-6: the lock is taken before the log starts, so tee must close
        # fd 9 or it would keep the lock after the script exits.
        with tempfile.TemporaryDirectory() as td:
            result = self.ok(
                'acquire_lock "$FIXTURE/lock"; start_log "$FIXTURE/log"; '
                "tee_pid=$!; sleep 0.2; "
                'for fd in /proc/"$tee_pid"/fd/*; do '
                '[ "$(readlink "$fd")" != "$FIXTURE/lock" ] || exit 7; done; '
                "echo TEE-CLEAN",
                env={"FIXTURE": td},
            )
            self.assertIn("TEE-CLEAN", (Path(td) / "log").read_text())
            self.assertNotIn("TEE-CLEAN", result.stderr)

    def test_second_run_does_not_write_into_active_log(self):
        # CR2-6: main takes the lock before starting the log, so a concurrent
        # run dies on the lock without appending to the first run's log.
        main_src = SCRIPT.read_text().split("\nmain() {", 1)[1]
        lock_at = main_src.index('acquire_lock "$LOCK_FILE"')
        log_at = main_src.index('start_log "$LOG_FILE"')
        self.assertLess(lock_at, log_at)

    def test_no_cli_tools_needs_no_target_user(self):
        with tempfile.TemporaryDirectory() as td:
            env = {
                "OS_RELEASE_FILE": write_os_release(td, "fedora", "43"),
                "SUDO_USER": "root",
            }
            code = "DRY_RUN=1; getent() { echo 'root:x:0:0:root:/root:/bin/bash'; }; "
            self.ok(
                code + 'DO_CLI_TOOLS=0; detect_system; [[ -z "$TARGET_USER" ]]', env=env
            )
            result = shell(code + "detect_system", env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("UID 0", result.stderr)

    def test_whole_dry_run_changes_nothing(self):
        cases = [
            (
                "fedora",
                "43",
                "--user audit --hostname new-host --remove-cockpit",
                [
                    "'dnf' 'install' '-y' 'kernel-cachyos' 'kernel-cachyos-devel-matched'",
                    "'grubby' '--update-kernel=ALL' '--args=selinux=0'",
                    "'systemctl' 'mask' 'firewalld'",
                    "'hostnamectl' 'set-hostname' 'new-host'",
                    "'dnf' 'remove' '-y' 'cockpit*'",
                    "'runuser' '-u' 'audit'",
                    "Installed kernel-cachyos as default",
                ],
            ),
            (
                "rocky",
                "10.1",
                "--keep-selinux --keep-firewall --no-cli-tools --java 21",
                [
                    "'dnf' 'install' '-y' 'epel-release'",
                    "'setsebool' '-P' 'domain_kernel_load_modules' 'on'",
                    "'dnf' 'install' '-y' 'java-21-openjdk-devel'",
                ],
            ),
        ]
        for os_id, version, flags, planned in cases:
            with self.subTest(os=os_id), tempfile.TemporaryDirectory() as td:
                result = shell(
                    DRY_RUN_STUBS + f"main --dry-run {flags}",
                    env={
                        "FIXTURE": td,
                        "OS_RELEASE_FILE": write_os_release(td, os_id, version),
                        "SUDO_USER": "root",
                    },
                )
                forbidden = Path(td) / "forbidden"
                self.assertFalse(
                    forbidden.exists(), forbidden.exists() and forbidden.read_text()
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("dry run: nothing was modified", result.stdout)
                # Every note is marked as hypothetical, and nothing claims a
                # reboot is needed now (CR-9: a dry run must not report state).
                summary = result.stdout.split("Summary (dry run", 1)[1]
                notes = [s for s in summary.splitlines() if s.startswith("  - ")]
                self.assertTrue(notes)
                for note in notes:
                    self.assertTrue(note.startswith("  - [would] "), note)
                self.assertNotIn("Reboot required", summary)
                self.assertIn("A real run would need a reboot", summary)
                for command in planned:
                    self.assertIn(command, result.stdout)

    def test_soft_failure_sets_partial(self):
        self.ok(
            "dnf() { return 42; }; dnf_install_soft one two; "
            '[[ "$PARTIAL_FAILURE" == 1 ]]; '
            '[[ "${SUMMARY[*]}" == *"one two"* ]]'
        )

    def test_soft_retry_success_not_partial(self):
        self.ok(
            "dnf() { (($# == 4)) && return 42; return 0; }; "
            'dnf_install_soft one two; [[ "$PARTIAL_FAILURE" == 0 ]]'
        )

    def test_dry_run_does_not_query_or_write(self):
        self.ok(
            "DRY_RUN=1; TARGET_USER=audit; TARGET_HOME=/nonexistent; "
            "dnf() { echo FORBIDDEN; exit 99; }; "
            "pkg_installed() { return 1; }; step_cli_tools"
        )

    def test_kernel_boot_image_uses_owned_module_release(self):
        result = self.ok(
            'rpm() { printf "%s\\n" /lib/modules/7.3.1-1.cachyos1.fc43.x86_64/vmlinuz '
            "/usr/lib/modules/7.3.10-1.cachyos1.fc43.x86_64/vmlinuz; }; "
            "kernel_boot_image kernel-cachyos"
        )
        self.assertEqual(
            result.stdout.strip(), "/boot/vmlinuz-7.3.10-1.cachyos1.fc43.x86_64"
        )

    def test_existing_kernel_repairs_devel_preserves_default(self):
        result = self.ok(
            "KERNEL_VARIANT=lts; secure_boot_state() { echo disabled; }; "
            "cpu_supports_level() { return 0; }; "
            'pkg_installed() { [[ "$1" != *-devel-matched ]]; }; '
            "ensure_kernel_boot_files() { :; }; "
            "grubby() { echo /boot/rollback; }; "
            'run() { echo "RUN $*"; }; step_kernel'
        )
        self.assertIn(
            "install -y kernel-cachyos-lts kernel-cachyos-lts-devel-matched",
            result.stdout,
        )
        self.assertIn("--set-default /boot/rollback", result.stdout)

    def test_keep_selinux_reports_kernel_module_boolean(self):
        base = (
            "KERNEL_VARIANT=lts; uname() { echo x86_64; }; "
            "secure_boot_state() { echo disabled; }; "
            "cpu_supports_level() { return 0; }; pkg_installed() { return 0; }; "
            "ensure_kernel_boot_files() { :; }; have() { return 0; }; "
            'run() { echo "RUN $*"; }; '
        )
        off = "getsebool() { echo 'domain_kernel_load_modules --> off'; }; "
        on = "getsebool() { echo 'domain_kernel_load_modules --> on'; }; "
        enabled = "selinuxenabled() { return 0; }; "
        for setup, changed in [
            ("DISABLE_SELINUX=0; " + enabled + off, True),
            ("DISABLE_SELINUX=1; " + enabled + off, False),
            ("DISABLE_SELINUX=0; selinuxenabled() { return 1; }; " + off, False),
            ("DISABLE_SELINUX=0; " + enabled + on, False),
        ]:
            with self.subTest(setup=setup):
                result = self.ok(
                    base + setup + 'step_kernel; printf "%s\\n" "${SUMMARY[@]}"'
                )
                self.assertEqual(
                    "RUN setsebool -P domain_kernel_load_modules on" in result.stdout,
                    changed,
                )
                self.assertEqual(
                    "domain_kernel_load_modules set to on for" in result.stdout,
                    changed,
                )

    def test_failed_kernel_module_boolean_names_policy(self):
        result = shell(
            "DISABLE_SELINUX=0; have() { return 0; }; selinuxenabled() { return 0; }; "
            "getsebool() { return 1; }; run() { return 1; }; allow_kernel_module_loading"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("check that the loaded policy defines it", result.stderr)

    def test_keep_selinux_preflight_needs_boolean_tools_only_when_enabled(self):
        # selinuxenabled exits 0 when SELinux is enabled.
        for missing, selinuxenabled_status, error in [
            ("[gs]etsebool", 1, None),
            ("[gs]etsebool", 0, "required command missing: getsebool"),
            ("selinuxenabled", 0, "required command missing: selinuxenabled"),
        ]:
            with self.subTest(missing=missing, status=selinuxenabled_status):
                result = shell(
                    "DISABLE_SELINUX=0; OS_VERSION=43; OS_FAMILY=fedora; "
                    "uname() { echo x86_64; }; secure_boot_state() { echo disabled; }; "
                    "cpu_supports_level() { return 0; }; pkg_installed() { return 0; }; "
                    f"selinuxenabled() {{ return {selinuxenabled_status}; }}; "
                    f'have() {{ [[ "$1" != {missing} ]]; }}; check_kernel_repository'
                )
                self.assertEqual(result.returncode, int(bool(error)), result.stderr)
                self.assertIn(error or "", result.stderr)

    def test_complete_kernel_installation_not_upgraded(self):
        result = self.ok(
            "pkg_installed() { return 0; }; "
            "run() { echo FORBIDDEN; exit 99; }; "
            "install_kernel_packages kernel-cachyos 0"
        )
        self.assertNotIn("FORBIDDEN", result.stdout)

    def test_fresh_kernel_failure_restores_old_default(self):
        result = shell(
            "pkg_installed() { return 0; }; "
            "grubby() { echo /boot/stock; }; "
            'run() { echo "RUN $*"; [[ "$1 $2" != "dnf install" ]]; }; '
            "install_kernel_packages kernel-cachyos 1"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--set-default /boot/stock", result.stdout)

    def test_interrupted_kernel_boot_files_repaired(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.ok(
                "kernel_boot_image() { echo /boot/vmlinuz-fixture; }; "
                'kernel_boot_ready() { test -f "$FIXTURE/repaired"; }; '
                "grubby() { echo /boot/rollback; }; "
                'run() { echo "RUN $*"; touch "$FIXTURE/repaired"; }; '
                "ensure_kernel_boot_files kernel-cachyos; "
                '[[ -z "$BOOT_DEFAULT_TO_RESTORE" ]]',
                env={"FIXTURE": td},
            )
            self.assertIn(
                "kernel-install add fixture /lib/modules/fixture/vmlinuz", result.stdout
            )
            self.assertIn("--set-default /boot/rollback", result.stdout)

    def test_complete_kernel_boot_files_unchanged(self):
        self.ok(
            "kernel_boot_image() { echo /boot/vmlinuz-fixture; }; "
            "kernel_boot_ready() { return 0; }; run() { exit 99; }; "
            "ensure_kernel_boot_files kernel-cachyos"
        )

    def test_failed_boot_repair_preserves_default_and_fails(self):
        result = shell(
            "kernel_boot_image() { echo /boot/vmlinuz-fixture; }; "
            "kernel_boot_ready() { return 1; }; "
            "grubby() { echo /boot/rollback; }; "
            'run() { echo "RUN $*"; [[ "$1" == grubby ]]; }; '
            "ensure_kernel_boot_files kernel-cachyos"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--set-default /boot/rollback", result.stdout)

    def test_failed_secure_boot_probe_is_unknown_on_efi(self):
        result = self.ok(
            "efi_booted() { return 0; }; have() { return 0; }; "
            "mokutil() { return 42; }; compgen() { return 1; }; secure_boot_state"
        )
        self.assertEqual(result.stdout.strip(), "unknown")

    def test_firmware_without_secure_boot_support_is_disabled(self):
        # Non-secboot OVMF (OVMF_CODE.4m.fd) has EFI variables but no SecureBoot.
        result = self.ok(
            "efi_booted() { return 0; }; have() { [[ $1 != mokutil ]]; }; "
            'compgen() { [[ "$2" == *SecureBoot-* ]] && return 1; echo var; }; '
            "secure_boot_state"
        )
        self.assertEqual(result.stdout.strip(), "disabled")

    def test_mokutil_unsupported_message_is_disabled(self):
        result = self.ok(
            "efi_booted() { return 0; }; have() { return 0; }; "
            'mokutil() { echo "This system doesn\'t support Secure Boot"; }; '
            "secure_boot_state"
        )
        self.assertEqual(result.stdout.strip(), "disabled")

    def test_secure_boot_fallback(self):
        for value, expected in ((0, "disabled"), (1, "enabled")):
            result = self.ok(
                "efi_booted() { return 0; }; have() { return 0; }; "
                "mokutil() { return 42; }; compgen() { echo fixture; }; "
                f"od() {{ echo {value}; }}; secure_boot_state"
            )
            self.assertEqual(result.stdout.strip(), expected)

    def test_atomic_edit_interrupted_before_replace(self):
        with tempfile.TemporaryDirectory() as td:
            rc = Path(td) / ".bashrc"
            original = b"user configuration remains intact\n"
            rc.write_bytes(original)
            result = shell(
                'TARGET_HOME="$FIXTURE"; as_user() { "$@"; }; '
                'python3() { [[ "$1" == -I ]] || exit 98; shift; '
                "command python3 -I -c '"
                "import os,sys; sys.argv=sys.argv[1:]; "
                "os.replace=lambda *args: os._exit(143); "
                'exec(compile(sys.stdin.read(), "editor", "exec"))\' "$@"; }; '
                "write_bashrc_block",
                env={"FIXTURE": td},
            )
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(rc.read_bytes(), original)
            self.assertEqual(self.edit_rc(td).returncode, 0)
            self.assertTrue(rc.read_bytes().startswith(original))

    def test_selinux_pending_reboot_on_rerun(self):
        result = self.ok(
            "getenforce() { echo Permissive; }; "
            "all_kernels_disable_selinux() { return 0; }; "
            'run() { echo "RUN $*"; }; step_selinux; echo "REBOOT=$NEED_REBOOT"'
        )
        self.assertIn("REBOOT=1", result.stdout)

    def test_secure_boot_unknown_or_enabled_skips_kernel(self):
        for state in ("unknown", "enabled"):
            result = self.ok(
                f"secure_boot_state() {{ echo {state}; }}; "
                "run() { echo FORBIDDEN; exit 99; }; step_kernel"
            )
            self.assertNotIn("FORBIDDEN", result.stdout)

    def test_cent_os_epel_uses_url(self):
        result = self.ok("OS_ID=centos; DRY_RUN=1; install_epel")
        self.assertIn(
            "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm",
            result.stdout,
        )

    def test_crb_dnf4_dnf5(self):
        for version, syntax in ((0, "--set-enabled crb"), (1, "setopt crb.enabled=1")):
            result = self.ok(
                f"IS_DNF5={version}; OS_ID=centos; DRY_RUN=1; "
                "pkg_installed() { return 1; }; enable_crb"
            )
            self.assertIn(syntax.replace(" ", "' '"), result.stdout)
            self.assertIn(
                "dnf5-plugins" if version else "dnf-plugins-core", result.stdout
            )

    def test_selinux_exact_tokens_and_all_entries(self):
        for args, expected in [
            ('args="quiet selinux=0"', 0),
            ('args="example_selinux=0"', 1),
            ('args="selinux=0"\nargs="quiet"', 1),
            ("", 1),
        ]:
            result = shell(
                'grubby() { printf "%s\\n" "$FIXTURE"; }; all_kernels_disable_selinux',
                env={"FIXTURE": args},
            )
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_main_incomplete_exit_status(self):
        result = shell(
            "detect_system() { :; }; preflight() { :; }; "
            "for step in package_health hostname dnf_conf repos build_tools kernel selinux firewall cockpit guest_tools cli_tools; do "
            'eval "step_${step}() { :; }"; done; '
            'step_java() { PARTIAL_FAILURE=1; note "incomplete Java"; }; '
            "main --dry-run"
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("incomplete Java", result.stdout)

    def test_damaged_rpm_state_stops_with_recovery_guidance(self):
        result = shell("dnf() { return 42; }; step_package_health; echo FORBIDDEN")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FORBIDDEN", result.stdout)
        self.assertIn("repair interrupted package transactions", result.stderr)

    def test_dry_run_does_not_check_rpm_state(self):
        self.ok("DRY_RUN=1; dnf() { exit 99; }; step_package_health")

    def test_pending_reboot_detected_before_steps(self):
        for boot, runtime, configured in [
            ("/boot/vmlinuz-new", "Disabled", 1),
            ("/boot/vmlinuz-running", "Permissive", 0),
        ]:
            self.ok(
                f"grubby() {{ echo {boot}; }}; getenforce() {{ echo {runtime}; }}; "
                "uname() { echo running; }; "
                f"all_kernels_disable_selinux() {{ return {configured}; }}; "
                'detect_pending_reboot; [[ "$NEED_REBOOT" == 1 ]]'
            )

    def test_running_default_and_disabled_selinux_need_no_reboot(self):
        self.ok(
            "grubby() { echo /boot/vmlinuz-running; }; "
            "uname() { echo running; }; getenforce() { echo Disabled; }; "
            'detect_pending_reboot; [[ "$NEED_REBOOT" == 0 ]]'
        )

    def test_unavailable_kernel_repository_fails_preflight(self):
        result = shell(
            "OS_VERSION=43; OS_FAMILY=fedora; "
            "secure_boot_state() { echo disabled; }; "
            "cpu_supports_level() { return 0; }; pkg_installed() { return 1; }; "
            "have() { return 0; }; curl() { return 22; }; check_kernel_repository"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("COPR repository unavailable for fedora-43", result.stderr)

    def test_complete_kernel_does_not_need_repository_probe(self):
        self.ok(
            "OS_VERSION=43; OS_FAMILY=fedora; "
            "secure_boot_state() { echo disabled; }; "
            "cpu_supports_level() { return 0; }; pkg_installed() { return 0; }; "
            "have() { return 0; }; curl() { exit 99; }; check_kernel_repository"
        )

    def test_missing_prerequisite_fails_preflight(self):
        result = shell('have() { [[ "$1" != python3 ]]; }; preflight')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required command missing: python3", result.stderr)

    def test_failure_and_signal_preserve_summary(self):
        for ending, status in (("false", 1), ("kill -TERM $$", 143)):
            result = shell(
                'SUMMARY_READY=1; NEED_REBOOT=1; note "already completed"; '
                "trap 'on_error $LINENO' ERR; trap on_exit EXIT; "
                "trap 'exit 143' TERM; " + ending
            )
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertIn("already completed", result.stdout)
            self.assertIn("Reboot required", result.stdout)

    def test_interruption_restores_rollback_default(self):
        result = shell(
            "SUMMARY_READY=1; BOOT_DEFAULT_TO_RESTORE=/boot/rollback; "
            'grubby() { echo "RESTORE $*"; }; '
            "trap on_exit EXIT; trap 'exit 143' TERM; kill -TERM $$"
        )
        self.assertEqual(result.returncode, 143)
        self.assertIn("RESTORE --set-default /boot/rollback", result.stdout)

    def test_tampered_installer_is_not_executed(self):
        with tempfile.TemporaryDirectory() as td:
            fixture = Path(td)
            (fixture / "curl").write_text(
                "#!/bin/sh\nfor destination do :; done\n"
                'cp "$FIXTURE/payload" "$destination"\n'
            )
            (fixture / "curl").chmod(0o755)
            (fixture / "payload").write_text('touch "$FIXTURE/executed"\n')
            result = shell(
                'as_user() { "$@"; }; '
                'run_user_installer https://example.invalid/install "$DIGEST"',
                env={
                    "FIXTURE": td,
                    "PATH": td + ":" + os.environ["PATH"],
                    "DIGEST": "0" * 64,
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILED", result.stdout + result.stderr)
            self.assertFalse((fixture / "executed").exists())

    def test_target_user_path_and_no_privilege_escalation(self):
        result = self.ok(
            "TARGET_USER=audit; TARGET_HOME=/home/audit; "
            'run() { printf "%s\\n" "$@"; }; as_user true'
        )
        self.assertIn("--no-new-privs", result.stdout)
        self.assertIn("env\n-i", result.stdout)
        self.assertIn("PATH=/home/audit/.local/bin:", result.stdout)

    def test_no_nested_if_statements(self):
        def check_shell(source):
            def walk(node, depth=0):
                if isinstance(node, list):
                    for item in node:
                        walk(item, depth)
                    return
                if not isinstance(node, dict):
                    return
                current = node.get("Type") == "IfClause"
                self.assertFalse(current and depth, f"nested if at {node.get('Pos')}")
                for value in node.values():
                    walk(value, depth + int(current))

            walk(shfmt_json(source))

        with self.assertRaises(AssertionError):
            check_shell("if true; then if true; then :; fi; fi")
        source = SCRIPT.read_text()
        check_shell(source)
        # Heredoc contents are not parsed as shell by the outer shell parser.
        rc_code = source.split('block = b"""', 1)[1].split('"""', 1)[0]
        check_shell(rc_code)
        # Apply the same rule to embedded Python editors.
        for block in source.split("<<'PYTHON'\n")[1:]:
            tree = ast.parse(block.split("\nPYTHON", 1)[0])
            for node in ast.walk(tree):
                if isinstance(node, ast.If):
                    descendants = [
                        child
                        for stmt in node.body + node.orelse
                        for child in ast.walk(stmt)
                    ]
                    self.assertFalse(
                        any(isinstance(child, ast.If) for child in descendants)
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
