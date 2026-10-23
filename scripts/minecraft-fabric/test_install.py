#!/usr/bin/env python3
"""Regression checks using disposable files and synthetic API/service commands.

Run with: python3 scripts/minecraft-fabric/test_install.py
No packages, services, firewall rules or Minecraft servers are installed.
"""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("install.sh")
SOURCE = SCRIPT.read_text()


def section(start, end):
    return SOURCE[SOURCE.index(start) : SOURCE.index(end, SOURCE.index(start))]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="fabric-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.server = self.root / "server with spaces"
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        (self.fixtures / "loader").write_text("0.20.1")
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "JAVA_HOME": str(self.root),
            "FIXTURES": str(self.fixtures),
            "SERVER": str(self.server),
            "TMPDIR": str(self.root),
        }
        self.tool(
            "systemctl",
            'if [[ $1 == show || $2 == show ]]; then echo "${UNIT_STATE:-inactive}"; exit 0; fi\nexit 3\n',
        )
        self.tool("ss", "exit 0\n")
        self.tool("sudo", 'echo "unexpected sudo call" >&2; exit 99\n')
        self.tool(
            "java",
            """if [[ " $* " == *" -version "* ]]; then
    [[ $1 != --enable-final-field-mutation=* ]] || exit 1
    echo 'openjdk version "25.0.1"' >&2
    exit 0
fi
printf '%s\\n' "$*" >>"$FIXTURES/java-calls"
if [[ ${BOOT_SERVER:-} == yes ]]; then
    mkdir -p config/Geyser-Fabric
    printf 'java:\\n  auth-type: online\\n' >config/Geyser-Fabric/config.yml
    trap 'exit 0' TERM
    echo 'Done (0.1s)!'
    while :; do sleep 0.1; done
fi
""",
        )
        payload = b"synthetic mod artifact"
        (self.fixtures / "payload").write_bytes(payload)
        digest = hashlib.sha512(payload).hexdigest()
        for slug, filename in (
            ("fabric-api", "fabric-api-9.0.jar"),
            ("geyser", "Geyser-Fabric-9.jar"),
            ("floodgate", "Floodgate-Fabric-9.jar"),
        ):
            (self.fixtures / f"{slug}.json").write_text(
                json.dumps(
                    [
                        {
                            "date_published": "2026-10-23T00:00:00Z",
                            "version_type": "release",
                            "version_number": "2.11.3-b1254"
                            if slug == "geyser"
                            else "9.0",
                            "files": [
                                {
                                    "filename": filename,
                                    "primary": True,
                                    "hashes": {"sha512": digest},
                                    "url": f"https://fixture/{filename}",
                                }
                            ],
                        }
                    ]
                )
            )
        self.tool(
            "curl",
            """import json, os, pathlib, sys
f = pathlib.Path(os.environ["FIXTURES"])
a = sys.argv[1:]
with (f / "curl-calls").open("a") as log:
    log.write(repr(a) + "\\n")
u = next(x for x in a if x.startswith("https://"))
if "-o" in a:
    pathlib.Path(a[a.index("-o") + 1]).write_bytes((f / "payload").read_bytes())
elif "/versions/game" in u:
    print(json.dumps([{"version": "1.21.1", "stable": True}]))
elif "/versions/loader/" in u:
    print(json.dumps([{"loader": {"version": (f / "loader").read_text(), "stable": True}}]))
elif "/versions/installer" in u:
    print(json.dumps([{"version": "1.1.2", "stable": True}]))
elif "version_manifest" in u:
    print(json.dumps({"versions": [{"id": "1.21.1", "url": "https://fixture/version.json"}]}))
elif u == "https://fixture/version.json":
    print(json.dumps({"javaVersion": {"majorVersion": 25}}))
elif "/project/" in u:
    print((f / (u.split("/project/")[1].split("/")[0] + ".json")).read_text())
else:
    sys.exit(19)
""",
            python=True,
        )

    def tool(self, name, body, python=False):
        path = self.bin / name
        path.write_text(
            ("#!/usr/bin/env python3\n" if python else "#!/usr/bin/env bash\n") + body
        )
        path.chmod(0o755)

    def bash(self, code, **env):
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + code],
            env=self.env | env,
            cwd=self.root,
            text=True,
            check=False,
            capture_output=True,
            timeout=20,
        )

    def install(self, *options, expected=0, **env):
        if os.geteuid() == 0:
            self.skipTest("the installer deliberately rejects root")
        result = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--yes",
                "--type",
                "java",
                "--service",
                "none",
                "--mc-version",
                "1.21.1",
                "--dir",
                str(self.server),
                "--heap",
                "1G",
                *options,
            ],
            env=self.env | env,
            text=True,
            check=False,
            capture_output=True,
            timeout=25,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {
            str(p.relative_to(self.server)): p.read_bytes()
            for p in self.server.rglob("*")
            if p.is_file()
        }

    def prepare_upgrade(self):
        self.install()
        old = self.server / "mods/fabric-api-8.0.jar"
        (self.server / "mods/fabric-api-9.0.jar").rename(old)
        old.write_bytes(b"previous managed mod")
        state = self.server / ".install-state"
        state.write_text(state.read_text().replace("fabric-api-9.0.jar", old.name))
        (self.fixtures / "loader").write_text("0.20.2")

    def fail_tool(self, name, condition, status=42):
        real = shutil.which(name)
        self.tool(
            name,
            f"""if {condition}; then
    echo 'injected {name} failure' >&2
    exit {status}
fi
exec {real} "$@"
""",
        )

    def test_fresh_install_and_unchanged_rerun(self):
        self.install()
        self.assertEqual((self.server / "eula.txt").read_text().strip(), "eula=false")
        (self.server / "world").mkdir()
        (self.server / "world/level.dat").write_bytes(b"saved world")
        (self.server / "mods/unrelated.jar").write_bytes(b"unmanaged mod")
        (self.server / "server.properties").write_text("server-port=25566\n")
        before = self.snapshot()
        (self.fixtures / "curl-calls").write_text("")
        self.install()
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn("'-o'", (self.fixtures / "curl-calls").read_text())
        result = subprocess.run(
            ["bash", "-n", str(self.server / "start.sh")],
            check=False,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0)

    def test_unmanaged_conflict_is_preserved_before_any_write(self):
        self.install()
        (self.server / "mods/fabric-api-0.0.0-custom.jar").write_bytes(b"custom build")
        before = self.snapshot()
        result = self.install(expected=1)
        self.assertIn("unmanaged mods/", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_unrecorded_modified_exact_filename_is_preserved(self):
        self.install()
        (self.server / ".install-state").unlink()
        (self.server / "mods/fabric-api-9.0.jar").write_bytes(b"custom same filename")
        before = self.snapshot()
        self.install(expected=1)
        self.assertEqual(self.snapshot(), before)

    def test_verified_legacy_artifact_can_be_adopted(self):
        self.install()
        (self.server / ".install-state").unlink()
        self.install()
        self.assertIn(
            "mod_fabric-api=fabric-api-9.0.jar",
            (self.server / ".install-state").read_text(),
        )

    def test_upgrade_removes_only_recorded_mods(self):
        self.prepare_upgrade()
        other = self.server / "mods/Floodgate-Fabric-custom.jar"
        other.write_bytes(b"unselected unmanaged mod")
        self.install()
        self.assertFalse((self.server / "mods/fabric-api-8.0.jar").exists())
        self.assertTrue((self.server / "mods/fabric-api-9.0.jar").exists())
        self.assertEqual(other.read_bytes(), b"unselected unmanaged mod")

    def test_copy_failure_restores_launcher_mods_and_state(self):
        self.prepare_upgrade()
        before = self.snapshot()
        self.fail_tool("install", '[[ " $* " == *"/mods/fabric-api-9.0.jar "* ]]')
        result = self.install(expected=42)
        self.assertIn("restored the previous", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.server.rglob(".install-file.*")))

    def test_second_mod_failure_rolls_back_first_replacement(self):
        self.prepare_upgrade()
        before = self.snapshot()
        self.fail_tool("install", '[[ " $* " == *"/mods/Geyser-Fabric-9.jar "* ]]')
        self.install("--type", "geyser", expected=42)
        self.assertEqual(self.snapshot(), before)

    def test_state_write_failure_restores_removed_mods(self):
        self.prepare_upgrade()
        before = self.snapshot()
        self.fail_tool("mv", "[[ ${!#} == */.install-state ]]")
        # The same simulated failure also blocks rollback of the state itself;
        # that file was never changed, and retained backups must be reported.
        result = self.install(expected=1)
        self.assertIn("artifact recovery failed", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(list(self.root.glob("tmp*/recovery-map")))

    def test_rename_failure_keeps_previous_file(self):
        self.prepare_upgrade()
        before = self.snapshot()
        self.fail_tool("mv", "[[ ${!#} == */mods/fabric-api-9.0.jar ]]")
        self.install(expected=42)
        self.assertEqual(self.snapshot(), before)

    def test_sigterm_during_replacement_rolls_back(self):
        self.prepare_upgrade()
        before = self.snapshot()
        real = shutil.which("install")
        self.tool(
            "install",
            f"""if [[ " $* " == *"/mods/fabric-api-9.0.jar "* ]]; then
    kill -TERM "$PPID"
    exit 143
fi
exec {real} "$@"
""",
        )
        self.install(expected=143)
        self.assertEqual(self.snapshot(), before)

    def test_launcher_rejects_pending_restart(self):
        self.install()
        result = self.bash('bash "$SERVER/start.sh"', UNIT_STATE="activating")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.fixtures / "java-calls").exists())
        result = self.bash('bash "$SERVER/start.sh"', UNIT_STATE="inactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.fixtures / "java-calls").exists())

    def service_loop(self, state, stop_state="inactive", scope="user"):
        self.server.mkdir()
        (self.root / "unit").write_text(f"WorkingDirectory={self.server}\n")
        (self.fixtures / "service-state").write_text(state)
        return self.bash(
            """UNIT_NAME=minecraft-fabric.service
service_mode=user
have_systemd=true
user_bus=true
server_dir=$SERVER
unit_file_for() { if [[ $1 == "$SCOPE" ]]; then echo "$FIXTURES/../unit"; else echo /nonexistent; fi; }
state_in() { cat "$FIXTURES/service-state"; }
ctl_in() { echo "$*" >>"$FIXTURES/service-calls"; if [[ $2 == stop ]]; then echo "$STOP_STATE" >"$FIXTURES/service-state"; fi; }
confirm() { return 0; }
sudo() { "$@"; } # simulated privilege boundary; all paths are disposable
warn() { :; }
die() { echo "$*" >&2; exit 1; }
"""
            + section(
                "was_running=false stopped_units=()",
                "if [[ $service_mode == system ]]; then\n\tsudo install -d",
            )
            + '\nprintf "was_running=%s\\n" "$was_running"\n',
            SCOPE=scope,
            STOP_STATE=stop_state,
        )

    def test_pending_restart_is_stopped_and_remembered(self):
        result = self.service_loop("activating")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("user stop", (self.fixtures / "service-calls").read_text())
        self.assertIn("was_running=true", result.stdout)

    def test_inactive_unit_is_stopped_to_cancel_jobs(self):
        result = self.service_loop("inactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("user stop", (self.fixtures / "service-calls").read_text())
        self.assertIn("was_running=false", result.stdout)

    def test_service_must_be_inactive_after_stop(self):
        result = self.service_loop("activating", stop_state="activating")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to update", result.stderr)

    def test_other_scope_service_is_also_stopped(self):
        result = self.service_loop("activating", scope="system")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("system stop", (self.fixtures / "service-calls").read_text())

    def shutdown(self, wrapper_alive=True, java_alive=True):
        return self.bash(
            """boot_pid=44444
boot_java_pid=44445
boot_pidfile=$FIXTURES/pid
boot_stop_failed=false
service_mode=none
echo 44445 >"$boot_pidfile"
alive() { if [[ $1 == 44444 ]]; then "$WRAPPER_ALIVE"; else "$JAVA_ALIVE"; fi; }
as_owner() { if [[ $1 == kill ]]; then return 1; fi; "$@"; }
warn() { echo "$*" >&2; }
sleep() { SECONDS=$((SECONDS + 121)); }
"""
            + section("shut_down_boot() {", "\nfirst_boot() {")
            + '\nif shut_down_boot; then echo stopped; else echo "blocked:$boot_pid:$boot_stop_failed"; exit 1; fi\n',
            WRAPPER_ALIVE=str(wrapper_alive).lower(),
            JAVA_ALIVE=str(java_alive).lower(),
        )

    def test_failed_shutdown_keeps_tracking_and_fails(self):
        result = self.shutdown()
        self.assertEqual(result.returncode, 1)
        self.assertIn("blocked:44444:true", result.stdout)
        self.assertTrue((self.fixtures / "pid").exists())

    def test_surviving_jvm_is_detected_after_wrapper_exits(self):
        result = self.shutdown(wrapper_alive=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.fixtures / "pid").exists())

    def test_completed_shutdown_removes_pid_file(self):
        result = self.shutdown(wrapper_alive=False, java_alive=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.fixtures / "pid").exists())

    def test_first_boot_child_is_stopped_and_floodgate_auth_set(self):
        self.install("--type", "floodgate", "--accept-eula", BOOT_SERVER="yes")
        self.assertIn(
            "auth-type: floodgate",
            (self.server / "config/Geyser-Fabric/config.yml").read_text(),
        )
        self.assertFalse((self.server / ".first-boot.pid").exists())

    def test_effective_geyser_ports(self):
        self.server.mkdir()
        (self.server / "server.properties").write_text("server-port=25566\n")
        directory = self.server / "config/Geyser-Fabric"
        directory.mkdir(parents=True)
        cases = [
            ("", "19132 19132"),
            ("bedrock:\n  port: 19133\n  clone-remote-port: true\n", "25566 0"),
            (
                "bedrock:\n    port: '19133' # custom\n    clone-remote-port: false\n",
                "19133 19133",
            ),
            (
                "bedrock:\n  port: 19133\n  webrtc-port: 19134\n  signaling:\n    port: 19135\n",
                "19134 19135",
            ),
            ("bedrock:\n  port: 19133\n  signaling:\n    mode: nxs\n", "19133 0"),
        ]
        for config, expected in cases:
            with self.subTest(config=config):
                (directory / "config.yml").write_text(config)
                result = self.bash(
                    """STATE_FILE=.install-state
JAVA_PORT=25565
BEDROCK_PORT=19132
server_dir=$SERVER
peek() { "$@" 2>/dev/null; }
info() { :; }
die() { exit 1; }
"""
                    + section("read_geyser_ports() {", "\nread_existing\n")
                    + '\nread_existing\nread_geyser_ports\necho "$bedrock_port $signaling_port"\n'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_java_install_ignores_unused_geyser_settings(self):
        self.install()
        directory = self.server / "config/Geyser-Fabric"
        directory.mkdir(parents=True)
        (directory / "config.yml").write_text("bedrock: {port: 19133}\n")
        self.install()
        self.install("--type", "geyser", expected=1)

    def test_exit_after_failed_boot_cleanup_preserves_logs_and_tracking(self):
        saved = self.fixtures / "saved-logs"
        saved.mkdir()
        pid = self.fixtures / "pid"
        pid.write_text("44445")
        result = self.bash(
            """tmp=$FIXTURES/saved-logs
boot_pid=44444
boot_pidfile=$FIXTURES/pid
boot_stop_failed=true
artifacts_pending=false
finished=false
stopped_units=(user)
UNIT_NAME=minecraft-fabric.service
warn() { echo "$*" >&2; }
"""
            + section("on_exit() {", "trap on_exit EXIT")
            + "on_exit\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue(saved.exists())
        self.assertTrue(pid.exists())
        self.assertIn("do not start another server", result.stderr)
        self.assertNotIn("systemctl --user start", result.stderr)

    def test_firewall_ports_follow_effective_listeners(self):
        result = self.bash(
            """java_port=25566
bedrock_port=19134
signaling_port=19135
server_type=geyser
"""
            + section('ports=("$java_port/tcp")', "if systemctl is-active -q firewalld")
            + '\nprintf "%s\\n" "${ports[@]}"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(), ["25566/tcp", "19134/udp", "19135/tcp"]
        )

    @unittest.skipUnless(
        shutil.which("systemd-analyze"), "systemd unit verifier unavailable"
    )
    def test_system_unit_home_with_spaces(self):
        self.server.mkdir()
        result = self.bash(
            """server_dir=$SERVER
service_mode=system
SYSTEM_USER=$(id -un)
system_group=$(id -gn)
mc_version=1.21.1
server_type=java
java_bin=/bin/true
java_args=()
unit_path=$FIXTURES/generated.service
sudo() { if [[ $1 == tee ]]; then "$@"; fi; }
"""
            + section("systemd_quote() {", "# The launcher command")
            + section(
                "if [[ $service_mode != none ]]; then\n\tif [[ $service_mode == system ]]; then",
                "# --- firewall",
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        unit = self.fixtures / "generated.service"
        self.assertIn(f'Environment="HOME={self.server}"', unit.read_text())
        check = subprocess.run(
            ["systemd-analyze", "verify", str(unit)],
            text=True,
            check=False,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertNotIn("Invalid environment assignment", check.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
