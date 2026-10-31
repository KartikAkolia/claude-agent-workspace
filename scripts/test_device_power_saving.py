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
options iwlmvm power_scheme=1
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
            "options iwlmvm power_scheme=2",
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
        ):
            self.tool(name, STUB)
        self.script = self.root / "disable-device-power-saving.sh"
        source = (SCRIPTS / self.script.name).read_text()
        source = source.replace("if ((EUID != 0)); then", "if false; then")
        for prefix in ("/etc/", "/sys/", "/var/lib/"):
            source = source.replace(prefix, str(self.root) + prefix)
        source = source.replace("BOOT_DIR=/boot", "BOOT_DIR=" + str(self.root / "boot"))
        self.script.write_text(source)
        shutil.copy2(SCRIPTS / "device-power-saving-config.py", self.root)
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
            ["bash", str(self.script), *map(str, args)],
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
            for parent in (("etc", "boot") if include_boot else ("etc",))
            for path in (self.root / parent).rglob("*")
            if path.is_file()
        }

    def latest(self):
        return (self.state / "current").resolve()

    def test_install_and_complete_undo(self):
        before = self.originals(include_boot=False)
        self.run_policy()
        self.assertEqual(
            json.loads((self.root / "wifi.json").read_text()),
            {"111-aaa": 2, "222-bbb": 2},
        )
        self.assertEqual(self.modprobe.stat().st_mode & 0o777, 0o600)
        self.run_policy("--undo", self.latest())
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

    def test_undo_refuses_later_dropin_or_profile_changes(self):
        self.run_policy()
        self.modprobe.write_text("# changed by user")
        before = self.originals()
        self.run_policy("--undo", self.latest(), success=False)
        self.assertEqual(self.originals(), before)

    def test_build_and_reload_failures_restore_originals(self):
        for command in ("mkinitcpio", "grub-mkconfig", "udevadm"):
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
        self.run_policy()
        source = self.latest()
        profiles = json.loads((self.root / "wifi.json").read_text())
        profiles["333-ccc"] = 9  # the stub crashes reading this one
        (self.root / "wifi.json").write_text(json.dumps(profiles))
        result = self.run_policy("--undo", source, success=False)
        self.assertIn("nmcli failed", result.stderr)
        self.assertTrue((source / "complete").exists())
        self.assertTrue((source / "boot").is_dir())
        self.assertEqual(self.latest(), source)
        aborted = [r for r in self.state.glob("run.*") if r != source]
        self.assertEqual(len(aborted), 1)
        self.assertTrue((aborted[0] / "aborted").exists())
        self.assertFalse((aborted[0] / "boot").exists())
        self.assertFalse((aborted[0] / "pending").exists())

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
if [[ $1 == --preserve=all && $2 == -- && $3 == */before/1 ]]; then
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
if [[ $1 == --preserve=all && $2 == -- && $3 == */after/1 ]]; then
    echo partial >"$4"
    exit 42
fi
exec {real_cp} "$@"
""",
        )
        before = self.originals()
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)

    def test_signal_during_write_rolls_back(self):
        real_mv = shutil.which("mv")
        self.tool(
            "mv",
            f"""#!/usr/bin/env bash
if [[ ${{!#}} == */etc/modprobe.d/no-power-saving.conf && ! -e "$HOST/signaled" ]]; then
    touch "$HOST/signaled"
    kill -TERM "$PPID"
    exit 143
fi
exec {real_mv} "$@"
""",
        )
        before = self.originals()
        self.run_policy(success=False)
        self.assertEqual(self.originals(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
