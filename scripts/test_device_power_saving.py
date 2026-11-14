#!/usr/bin/env python3
"""Disposable regression tests; never touch host config, devices or boot files."""

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location(
    "policy", SCRIPTS / "device-power-saving-config.py"
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
MODULES = """options snd_hda_intel power_save=0 power_save_controller=N
options nvidia NVreg_DynamicPowerManagement=0x00
options mt7921e disable_aspm=Y
"""
STUB = r"""#!/usr/bin/env python3
import json, os
from pathlib import Path
import subprocess, sys
root = Path(os.environ['HOST'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
fail = root / 'fail'
if fail.exists() and fail.read_text() == name:
    fail.unlink()
    if name == 'mkinitcpio':
        (root / 'boot/initramfs-custom.img').write_text('partial image')
    if name == 'grub-mkconfig':
        (root / 'boot/grub/grub.cfg').write_text('partial config')
    sys.exit(42)
if name == 'nmcli':
    store = root / 'wifi.json'
    profiles = json.loads(store.read_text())
    failure = root / 'fail-profile'
    if args[:2] == ['connection', 'modify'] and failure.exists() and failure.read_text() == args[3]:
        failure.unlink()
        sys.exit(43)
    if args == ['-t', '-f', 'UUID,TYPE', 'connection', 'show']:
        for uuid in profiles:
            print(uuid + ':802-11-wireless')
    elif args[:2] == ['-g', '802-11-wireless.powersave']:
        value = profiles[args[-1]]
        label = ['default', 'ignore', 'disable', 'enable'][value]
        if (root / 'blank-powersave').exists():
            print('')
        elif (root / 'blank-after-modify').exists() and (root / 'modified').exists():
            print('')
        elif (root / 'numeric-powersave').exists():
            print(f'{value} ({label})')
        else:
            print(label)
    elif args[:2] == ['connection', 'modify']:
        profiles[args[3]] = int(args[-1])
        (root / 'modified').write_text('')
        store.write_text(json.dumps(profiles))
elif name == 'setpci':
    store = root / 'lnkctl.json'
    links = json.loads(store.read_text()) if store.exists() else {}
    if args[1] not in links:
        sys.exit(1)
    if args[2] == 'CAP_EXP+10.w':
        print(links[args[1]])
    elif args[2] == 'CAP_EXP+10.w=0:3':
        if (root / 'fail-setpci').exists():
            sys.exit(1)
        links[args[1]] = format(int(links[args[1]], 16) & ~3, '04x')
        store.write_text(json.dumps(links))
elif name == 'modprobe':
    print((root / 'etc/modprobe.d/no-power-saving.conf').read_text())
    print((root / 'effective-modules').read_text())
elif name == 'mkinitcpio':
    (root / 'boot/initramfs-custom.img').write_text('new image')
elif name == 'grub-mkconfig':
    defaults = root / 'etc/default/grub'
    result = subprocess.run(['bash', '-c', '. "$1"; printf "%s" "$GRUB_CMDLINE_LINUX_DEFAULT"', 'fixture', str(defaults)], capture_output=True, text=True, check=True)
    (root / 'boot/grub/grub.cfg').write_text('linux /vmlinuz-test ' + result.stdout)
"""


class GrubTests(unittest.TestCase):
    def test_comments_do_not_satisfy_policy(self):
        source = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet" # ' + " ".join(
            f"{k}={v}" for k, v in POLICY.PARAMS.items()
        )
        fixed = POLICY.grub(source)
        self.assertEqual(
            POLICY.managed(POLICY.read_grub(fixed)[4]),
            [f"{k}={v}" for k, v in POLICY.PARAMS.items()],
        )
        self.assertEqual(POLICY.grub(fixed), fixed)

    def test_all_duplicate_tokens_replaced_exactly(self):
        source = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet x.usbcore.autosuspend=7 usbcore.autosuspend=2 usbcore.autosuspend=9"\n'
        result = POLICY.grub(source)
        self.assertIn("x.usbcore.autosuspend=7", result)
        self.assertEqual(POLICY.read_grub(result)[4].count("usbcore.autosuspend=-1"), 1)
        self.assertNotIn("usbcore.autosuspend=2", result)
        self.assertNotIn("usbcore.autosuspend=9", result)

    def test_ambiguous_and_dynamic_assignments_rejected(self):
        for text in (
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_CMDLINE_LINUX_DEFAULT="other"\n',
            'GRUB_CMDLINE_LINUX_DEFAULT="$OTHER quiet"\n',
            'GRUB_CMDLINE_LINUX_DEFAULT="$(touch /tmp/unwanted)"\n',
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet -- init"\n',
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet\\\nother"\n',
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                POLICY.grub(text)

    def test_single_quotes_and_undo_preserve_unrelated_edits(self):
        original = "GRUB_TIMEOUT=5\nexport GRUB_CMDLINE_LINUX_DEFAULT='quiet usbcore.autosuspend=9' # keep\n"
        installed = POLICY.grub(original).replace("GRUB_TIMEOUT=5", "GRUB_TIMEOUT=8")
        undone = POLICY.grub(installed, original)
        self.assertIn("GRUB_TIMEOUT=8", undone)
        self.assertIn("'quiet usbcore.autosuspend=9' # keep", undone)

    def test_undo_rejects_changed_managed_tokens(self):
        original = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n'
        changed = POLICY.grub(original).replace(
            "usbcore.autosuspend=-1", "usbcore.autosuspend=2"
        )
        with self.assertRaises(ValueError):
            POLICY.grub(changed, original)

    def test_generated_grub_must_have_effective_policy(self):
        params = " ".join(f"{k}={v}" for k, v in POLICY.PARAMS.items())
        POLICY.boot("linux /vmlinuz-test " + params + "\nlinux /vmlinuz-test single")
        for text in (
            "linux /vmlinuz-test quiet",
            "# " + params,
            "linux /vmlinuz-test " + params + " usbcore.autosuspend=2",
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                POLICY.boot(text)

    def test_effective_module_overrides_are_verified(self):
        POLICY.modules(MODULES)
        for conflict in (
            "options nvidia NVreg_DynamicPowerManagement=0x03",
            "options snd-hda-intel power_save=10",
            "options snd_hda_intel power_save_controller=Y",
            "options mt7921e disable_aspm=N",
        ):
            with self.subTest(conflict=conflict), self.assertRaises(ValueError):
                POLICY.modules(MODULES + conflict)
        POLICY.modules("options nvidia NVreg_DynamicPowerManagement=0x03\n" + MODULES)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="device-policy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "var/lib/device-power-saving"
        self.grub = self.root / "etc/default/grub"
        self.grub.parent.mkdir(parents=True)
        self.grub.write_text(
            'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet usbcore.autosuspend=2"\n'
        )
        self.grub.chmod(0o640)
        for directory in (
            "etc/udev/rules.d",
            "etc/modprobe.d",
            "etc/NetworkManager/conf.d",
            "boot/grub",
        ):
            (self.root / directory).mkdir(parents=True)
        (self.root / "boot/grub/grub.cfg").write_text("original config")
        (self.root / "boot/initramfs-custom.img").write_text("original image")
        self.modprobe = self.root / "etc/modprobe.d/no-power-saving.conf"
        self.modprobe.write_text("# original options\n")
        self.modprobe.chmod(0o600)
        (self.root / "wifi.json").write_text(json.dumps({"111-aaa": 3, "222-bbb": 0}))
        (self.root / "effective-modules").write_text("")
        for path, content in (
            ("sys/module/usbcore/parameters/autosuspend", "2"),
            ("sys/module/pcie_aspm/parameters/policy", "default"),
            ("sys/bus/pci/devices/fixture/power/control", "auto"),
        ):
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        for name in (
            "nmcli",
            "modprobe",
            "mkinitcpio",
            "grub-mkconfig",
            "udevadm",
            "iw",
            "setpci",
            "systemctl",
        ):
            self.tool(name, STUB)
        self.tool("sleep", "#!/bin/sh\nexit 0\n")  # the late pass's recheck delay
        self.script = self.root / "disable-device-power-saving.sh"
        source = (SCRIPTS / self.script.name).read_text()
        source = source.replace("if ((EUID != 0)); then", "if false; then")
        for prefix in ("/etc/", "/sys/", "/var/lib/", "/usr/local/"):
            source = source.replace(prefix, str(self.root) + prefix)
        source = source.replace("BOOT_DIR=/boot", "BOOT_DIR=" + str(self.root / "boot"))
        self.script.write_text(source)
        shutil.copy2(SCRIPTS / "device-power-saving-config.py", self.root)
        self.late = [
            self.root / "etc/systemd/system/device-power-late.service",
            self.root / "etc/systemd/system/multi-user.target.d/device-power-late.conf",
            self.root / "usr/local/sbin/device-power-late",
            self.root / "etc/systemd/system/suspend.target.d/device-power-late.conf",
        ]
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOST": str(self.root),
        }

    def tool(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_policy(self, *args, success=True):
        result = subprocess.run(
            [
                # Reset the dispositions a nohup or background runner leaves
                # ignored (bash can't trap a signal ignored on entry), and
                # export the script's own PID for stubs that signal it.
                "env",
                "--default-signal=HUP,INT,TERM",
                "bash",
                "-c",
                'export POLICY_PID=$$; exec bash "$@"',
                "bash",
                str(self.script),
                *map(str, args),
            ],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(list(self.root.rglob(".device-power.*")))
        return result

    def originals(self, include_boot=True):
        return {
            str(path.relative_to(self.root)): (
                path.read_bytes(),
                path.stat().st_mode & 0o777,
            )
            for parent in (("etc", "usr", "boot") if include_boot else ("etc", "usr"))
            for path in (self.root / parent).rglob("*")
            if path.is_file()
        }

    def latest(self):
        return (self.state / "current").resolve()

    def runs(self):
        return set(self.state.glob("run.*"))

    def new_run(self, earlier):
        (run,) = self.runs() - earlier
        return run

    def test_install_and_complete_undo(self):
        before = self.originals(include_boot=False)
        self.run_policy()
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 2, "222-bbb": 2},
        )
        self.assertEqual(self.modprobe.stat().st_mode & 0o777, 0o600)
        self.assertEqual(
            [path.stat().st_mode & 0o777 for path in self.late],
            [0o644, 0o644, 0o755, 0o644],
        )
        self.assertIn("ExecStart=" + str(self.late[2]), self.late[0].read_text())
        self.assertIn("Wants=device-power-late.service", self.late[1].read_text())
        self.assertEqual(self.late[1].read_text(), self.late[3].read_text())
        self.assertIn("suspend.target", self.late[0].read_text())
        calls = (self.root / "calls").read_text()
        self.assertIn('["systemctl", "daemon-reload"]', calls)
        self.assertIn('["systemctl", "start", "device-power-late.service"]', calls)
        self.run_policy("--undo", self.latest())
        self.assertFalse(any(path.exists() for path in self.late))
        self.assertEqual(self.originals(include_boot=False), before)
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 3, "222-bbb": 0},
        )
        calls = (self.root / "calls").read_text()
        self.assertIn('["udevadm", "control", "--reload"]', calls)
        self.assertFalse((self.state / "current").exists())

    def test_rerun_and_reverse_order_undo(self):
        before = self.originals(include_boot=False)
        self.run_policy()
        first = self.latest()
        self.run_policy()
        second = self.latest()
        self.run_policy("--undo", first, success=False)
        self.run_policy("--undo", second)
        self.assertEqual(self.latest(), first)
        self.run_policy("--undo", first)
        self.assertEqual(self.originals(include_boot=False), before)

    def test_undo_preserves_later_unrelated_grub_edit(self):
        self.run_policy()
        self.grub.write_text(
            self.grub.read_text().replace("GRUB_TIMEOUT=5", "GRUB_TIMEOUT=9")
        )
        self.run_policy("--undo", self.latest())
        self.assertIn("GRUB_TIMEOUT=9", self.grub.read_text())
        self.assertIn("usbcore.autosuspend=2", self.grub.read_text())

    def test_undo_of_backup_predating_late_pass(self):
        before = self.originals(include_boot=False)
        self.run_policy()
        run = self.latest()
        for i in (4, 5, 6, 7):
            (run / "after" / str(i)).unlink()
        result = self.run_policy("--undo", run, success=False)
        self.assertIn("was not installed by this run", result.stderr)
        for path in self.late:
            path.unlink()
        self.run_policy("--undo", run)
        self.assertEqual(self.originals(include_boot=False), before)

    def late_fixture(self):
        self.run_policy()
        devices = self.root / "sys/devices/pci0000:00"
        bus = self.root / "sys/bus/pci/devices"
        for name, control in (
            ("0000:00:02.4", "on"),
            ("0000:00:02.4/0000:03:00.0", "auto"),
            ("0000:00:08.0", "auto"),
            ("0000:00:09.0", "on"),
        ):
            (devices / name / "power").mkdir(parents=True)
            (devices / name / "power/control").write_text(control)
            (bus / name.split("/")[-1]).symlink_to(devices / name)
        links = {
            "0000:00:02.4": "0042",
            "0000:03:00.0": "0142",
            "0000:00:08.0": "0040",
            "0000:00:09.0": "ffff",
        }
        (self.root / "lnkctl.json").write_text(json.dumps(links))
        (self.root / "calls").write_text("")
        return bus

    def run_late(self):
        return subprocess.run(
            [str(self.late[2])],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )

    def test_late_pass_clears_aspm_downstream_first(self):
        bus = self.late_fixture()
        # An unwritable control only warns; it must not fail the unit.
        (bus / "fixture/power/control").unlink()
        (bus / "fixture/power/control").mkdir()
        result = self.run_late()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: cannot write", result.stderr)
        self.assertEqual(
            json.loads((self.root / "lnkctl.json").read_text()),
            {
                "0000:00:02.4": "0040",
                "0000:03:00.0": "0140",
                "0000:00:08.0": "0040",
                "0000:00:09.0": "ffff",
            },
        )
        writes = [
            json.loads(line)[2]
            for line in (self.root / "calls").read_text().splitlines()
            if line.endswith('"CAP_EXP+10.w=0:3"]')
        ]
        self.assertEqual(writes, ["0000:03:00.0", "0000:00:02.4"])
        controls = {
            path.read_text().strip()
            for path in bus.glob("*/power/control")
            if path.is_file()
        }
        self.assertEqual(controls, {"on"})

    def test_late_pass_fails_on_aspm_write_error(self):
        self.late_fixture()
        (self.root / "fail-setpci").write_text("")
        self.assertEqual(self.run_late().returncode, 1)

    def test_failed_late_start_keeps_install(self):
        self.tool("systemctl", '#!/bin/sh\n[ "$1" = start ] && exit 5\nexit 0\n')
        result = self.run_policy()
        self.assertIn("Late pass failed", result.stderr)
        self.assertTrue((self.latest() / "complete").exists())

    def test_existing_helper_mode_does_not_block_execution(self):
        self.late[2].parent.mkdir(parents=True)
        self.late[2].write_text("# old helper\n")
        self.late[2].chmod(0o644)
        before = self.originals(include_boot=False)
        self.run_policy()
        self.assertEqual(self.late[2].stat().st_mode & 0o777, 0o755)
        self.run_policy("--undo", self.latest())
        self.assertEqual(self.originals(include_boot=False), before)

    def test_undo_refuses_later_dropin_or_profile_changes(self):
        self.run_policy()
        self.modprobe.write_text("# changed by user")
        before = self.originals()
        self.run_policy("--undo", self.latest(), success=False)
        self.assertEqual(self.originals(), before)

    def test_build_and_reload_failures_restore_originals(self):
        for command in ("mkinitcpio", "grub-mkconfig", "udevadm", "systemctl"):
            with self.subTest(command=command):
                before = self.originals()
                (self.root / "fail").write_text(command)
                result = self.run_policy(success=False)
                self.assertIn("restored", result.stderr)
                self.assertEqual(self.originals(), before)
                self.assertEqual(
                    json.loads((self.root / "wifi.json").read_text()),
                    {"111-aaa": 3, "222-bbb": 0},
                )

    def test_partial_profile_failure_restores_previous_values(self):
        before = self.originals()
        (self.root / "fail-profile").write_text("222-bbb")
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 3, "222-bbb": 0},
        )

    def test_failed_undo_restores_installed_policy_and_can_retry(self):
        self.run_policy()
        original_run = self.latest()
        before = self.originals()
        (self.root / "fail").write_text("grub-mkconfig")
        self.run_policy("--undo", original_run, success=False)
        self.assertEqual(self.originals(), before)
        self.assertFalse((original_run / "undone").exists())
        self.assertEqual(self.latest(), original_run)
        self.run_policy("--undo", original_run)

    def test_numeric_powersave_output_is_accepted(self):
        (self.root / "numeric-powersave").write_text("")
        self.run_policy()
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 2, "222-bbb": 2},
        )
        self.run_policy("--undo", self.latest())
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 3, "222-bbb": 0},
        )

    def test_undo_reports_unreadable_profile(self):
        self.run_policy()
        self.tool("nmcli", "#!/bin/sh\nexit 0\n")
        result = self.run_policy("--undo", self.latest(), success=False)
        self.assertIn("cannot read Wi-Fi policy", result.stdout + result.stderr)

    def test_install_reports_unreadable_profile(self):
        before = self.originals()
        (self.root / "blank-after-modify").write_text("")
        result = self.run_policy(success=False)
        self.assertIn("cannot read Wi-Fi policy", result.stderr)
        self.assertIn("unrecognised nmcli powersave output", result.stderr)
        self.assertIn("restored", result.stderr)
        self.assertEqual(self.originals(), before)
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 3, "222-bbb": 0},
        )

    def test_early_failure_drops_boot_snapshot(self):
        before = self.originals()
        (self.root / "blank-powersave").write_text("")
        result = self.run_policy(success=False)
        self.assertIn("cannot read Wi-Fi policy", result.stderr)
        self.assertEqual(self.originals(), before)
        runs = list(self.state.glob("run.*"))
        self.assertEqual(len(runs), 1)
        self.assertFalse((runs[0] / "boot").exists())
        self.assertTrue((runs[0] / "aborted").exists())
        self.assertFalse((runs[0] / "pending").exists())
        self.assertIn("partial run kept for diagnosis", result.stderr)
        (self.root / "blank-powersave").unlink()
        self.run_policy()  # an aborted run doesn't block the next install
        self.assertTrue((runs[0] / "aborted").exists())
        self.assertEqual(len(list(self.state.glob("run.*"))), 2)

    def test_failed_undo_keeps_source_backup(self):
        before = self.originals(include_boot=False)
        self.run_policy()
        source = self.latest()
        profiles = json.loads((self.root / "wifi.json").read_text())
        profiles["333-ccc"] = 9  # the stub crashes reading this one
        (self.root / "wifi.json").write_text(json.dumps(profiles))
        result = self.run_policy("--undo", source, success=False)
        self.assertIn("nmcli failed", result.stderr)
        self.assertTrue((source / "complete").exists())
        self.assertFalse((source / "undone").exists())
        # The completed source dropped its /boot copy; undo never reads it.
        self.assertFalse((source / "boot").exists())
        self.assertEqual(self.latest(), source)
        aborted = [r for r in self.state.glob("run.*") if r != source]
        self.assertEqual(len(aborted), 1)
        self.assertTrue((aborted[0] / "aborted").exists())
        self.assertFalse((aborted[0] / "boot").exists())
        self.assertFalse((aborted[0] / "pending").exists())
        # The kept source backup still undoes once the cause is fixed.
        del profiles["333-ccc"]
        (self.root / "wifi.json").write_text(json.dumps(profiles))
        self.run_policy("--undo", source)
        self.assertEqual(self.originals(include_boot=False), before)

    def test_only_unfinished_runs_keep_boot_snapshot(self):
        # A completed install drops its /boot copy.
        self.run_policy()
        installed = self.latest()
        self.assertTrue((installed / "complete").exists())
        self.assertTrue((installed / "before/3").is_file())
        self.assertFalse((installed / "boot").exists())
        # An install that fails and rolls back keeps it.
        earlier = self.runs()
        (self.root / "fail").write_text("grub-mkconfig")
        self.run_policy(success=False)
        failed = self.new_run(earlier)
        self.assertFalse((failed / "pending").exists())
        self.assertFalse((failed / "complete").exists())
        self.assertTrue((failed / "boot/grub/grub.cfg").is_file())
        # So does a failed undo; a successful one drops its own copy.
        earlier = self.runs()
        (self.root / "fail").write_text("mkinitcpio")
        self.run_policy("--undo", installed, success=False)
        self.assertTrue((self.new_run(earlier) / "boot/grub/grub.cfg").is_file())
        earlier = self.runs()
        self.run_policy("--undo", installed)
        self.assertTrue((installed / "undone").exists())
        self.assertFalse((self.new_run(earlier) / "boot").exists())

    def test_rewritten_files_get_fresh_mtime(self):
        old = 946684800  # 2000-01-01, before any run
        for path in (self.grub, self.modprobe):
            os.utime(path, (old, old))
        self.run_policy()
        for path in (self.grub, self.modprobe, *self.late):
            with self.subTest(path=path):
                self.assertGreater(path.stat().st_mtime, old + 86400)
        self.assertEqual(self.grub.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.modprobe.stat().st_mode & 0o777, 0o600)

    def test_undo_refuses_changed_profile(self):
        self.run_policy()
        (self.root / "wifi.json").write_text(json.dumps({"111-aaa": 3, "222-bbb": 2}))
        before = self.originals()
        self.run_policy("--undo", self.latest(), success=False)
        self.assertEqual(self.originals(), before)

    def test_incomplete_rollback_can_be_recovered_explicitly(self):
        real_cp = shutil.which("cp")
        self.tool(
            "cp",
            f"""#!/usr/bin/env bash
if [[ $1 == --preserve=all && $2 == --no-preserve=timestamps && $3 == -- && $4 == */before/1 ]]; then
    exit 44
fi
exec {real_cp} "$@"
""",
        )
        before = self.originals()
        (self.root / "fail").write_text("mkinitcpio")
        result = self.run_policy(success=False)
        self.assertIn("RECOVERY INCOMPLETE", result.stderr)
        backups = list(self.state.glob("run.*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "pending").exists())
        # A run still pending recovery keeps the /boot copy --recover restores.
        self.assertTrue((backups[0] / "boot/grub/grub.cfg").is_file())
        self.assertIn("unfinished recovery", self.run_policy(success=False).stderr)
        (self.bin / "cp").unlink()
        self.run_policy("--recover", backups[0])
        self.assertEqual(self.originals(), before)
        self.assertFalse((backups[0] / "pending").exists())

    def test_generated_boot_override_rolls_back(self):
        self.tool(
            "grub-mkconfig",
            "#!/usr/bin/env bash\necho 'linux /vmlinuz quiet' >\"$HOST/boot/grub/grub.cfg\"\n",
        )
        before = self.originals()
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)

    def test_conflicting_modules_fail_before_boot_build(self):
        before = self.originals()
        (self.root / "effective-modules").write_text(
            MODULES + "options nvidia NVreg_DynamicPowerManagement=3\n"
        )
        result = self.run_policy(success=False)
        self.assertIn("resolve modprobe.d", result.stderr)
        self.assertEqual(self.originals(), before)
        self.assertNotIn("mkinitcpio", (self.root / "calls").read_text())

    def test_grub_rejection_precedes_all_managed_writes(self):
        self.grub.write_text(
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_CMDLINE_LINUX_DEFAULT="other"\n'
        )
        before = self.originals()
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text())["111-aaa"], 3
        )

    def test_partial_copy_does_not_truncate_existing_file(self):
        real_cp = shutil.which("cp")
        self.tool(
            "cp",
            f"""#!/usr/bin/env bash
if [[ $1 == --preserve=all && $2 == --no-preserve=timestamps && $3 == -- && $4 == */after/1 ]]; then
    echo partial >"$5"
    exit 42
fi
exec {real_cp} "$@"
""",
        )
        before = self.originals()
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)

    def test_signal_during_write_rolls_back(self):
        # The stub signals the main script, not its parent place() subshell,
        # and the write itself succeeds, so only a signal can cause the
        # rollback. Exit status 1 is finish's own: without the main INT/TERM/HUP
        # traps, bash would run finish and then die by the signal instead.
        real_mv = shutil.which("mv")
        before = self.originals()
        for sig in ("INT", "TERM", "HUP"):
            with self.subTest(signal=sig):
                (self.root / "signaled").unlink(missing_ok=True)
                self.tool(
                    "mv",
                    f"""#!/usr/bin/env bash
if [[ ${{!#}} == */etc/modprobe.d/no-power-saving.conf && ! -e "$HOST/signaled" ]]; then
    touch "$HOST/signaled"
    kill -{sig} "$POLICY_PID"
fi
exec {real_mv} "$@"
""",
                )
                result = self.run_policy(success=False)
                self.assertTrue((self.root / "signaled").exists())
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Installation failed; restoring", result.stderr)
                self.assertIn("restored", result.stderr)
                self.assertEqual(self.originals(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
