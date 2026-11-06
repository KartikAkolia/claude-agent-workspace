#!/usr/bin/env python3
"""Installer regressions. No root, package installation, or host changes required.

Mandatory style gate: no nested shell if statements, including generated shell
blocks. Run with shfmt on PATH: python3 scripts/test_install_fedora.py.
"""

import ast
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("install-fedora.sh").resolve()
BEGIN = "# >>> install-fedora.sh >>>\n"
END = "# <<< install-fedora.sh <<<\n"


def shell(code, *, env=None):
    return subprocess.run(
        ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n{code}"],
        text=True,
        capture_output=True,
        env=os.environ | (env or {}),
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
            self.assertEqual(self.edit_rc(td).returncode, 0)
            first = rc.read_bytes()
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
            code = 'update_dnf_conf "$FIXTURE"'
            self.ok(code, env={"FIXTURE": str(conf)})
            first = conf.read_bytes()
            self.assertIn(b"[custom]\nfastestmirror=False", first)
            self.assertIn(b"[other]\nmax_parallel_downloads=2", first)
            self.assertNotIn(b"defaultyes=False", first)
            self.assertIn(b"keep=True", first)
            self.assertEqual(conf.stat().st_mode & 0o777, 0o640)
            self.ok(code, env={"FIXTURE": str(conf)})
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
                "python3() { command python3 -c '"
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
            result = subprocess.run(
                ["shfmt", "-tojson"],
                input=source,
                text=True,
                capture_output=True,
                check=True,
            )

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

            walk(json.loads(result.stdout))

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
