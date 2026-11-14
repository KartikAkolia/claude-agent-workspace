#!/usr/bin/env python3
"""lib/tui.sh wiring for the three whiptail TUIs.

Starts each TUI with a PATH holding only dirname and readlink (all it needs
to find the lib), so it stops at require_tools before drawing anything: no
whiptail, display, audio or camera command ever runs.

Run: python3 scripts/test_tui_lib.py
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE / "lib" / "tui.sh"
# Each TUI, and the tools its require_tools call names, in order.
TUIS = {
    "audio-tui.sh": "whiptail pactl jq",
    "display-tui.sh": "whiptail xrandr awk mktemp rm",
    "webcam-tui.sh": "whiptail v4l2-ctl awk grep",
}
# The lib's original interface, which sync-root-gtk-theme.sh is held to
# below, and everything the lib provides now. The TUIs are held to every
# function the lib defines (LIB_FUNCS), so one added later is covered too.
SHARED = ("wt", "die", "require_tools")
INTERFACE = (*SHARED, "run_or_report", "normalize_int", "int_le")
LIB_FUNCS = re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\) \{$", LIB.read_text())
BASH = shutil.which("bash")


def run_tui(script, workdir):
    """Run a TUI with only dirname and readlink on PATH."""
    bindir = Path(workdir) / "bin"
    bindir.mkdir(exist_ok=True)
    for tool in ("dirname", "readlink"):
        link = bindir / tool
        if not link.exists():
            link.symlink_to(shutil.which(tool))
    return subprocess.run(
        [BASH, str(script)],
        check=False,
        cwd=workdir,
        env={"PATH": str(bindir), "HOME": str(workdir)},
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=20,
    )


class TuiLibTests(unittest.TestCase):
    def test_shared_helpers_live_only_in_the_lib(self):
        lib = LIB.read_text()
        for name in INTERFACE:
            self.assertIn(name, LIB_FUNCS, f"lib/tui.sh doesn't define {name}()")
        prog = re.search(r"(?m)^readonly PROG=", lib)
        self.assertIsNotNone(prog, "lib/tui.sh doesn't set PROG")
        for tui in TUIS:
            text = (HERE / tui).read_text()
            with self.subTest(tui=tui):
                for name in LIB_FUNCS:
                    own = re.search(rf"(?m)^{name}\(\)", text)
                    self.assertIsNone(own, f"{tui} defines its own {name}()")
                own_prog = re.search(r"(?m)^readonly PROG=", text)
                self.assertIsNone(own_prog, f"{tui} sets its own PROG")
                finds = re.search(r'(?m)^tui_lib=.*/lib/tui\.sh"$', text)
                self.assertIsNotNone(finds, f"{tui} doesn't look for lib/tui.sh")
                sources = re.search(r'(?m)^\. "\$tui_lib"$', text)
                self.assertIsNotNone(sources, f"{tui} doesn't source the lib")

    def test_lib_is_found_from_the_repo_and_through_a_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            for tui, tools in TUIS.items():
                link = Path(tmp) / f"link-{tui}"
                link.symlink_to(HERE / tui)
                for script in (HERE / tui, link):
                    with self.subTest(script=str(script)):
                        result = run_tui(script, tmp)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertEqual(
                            result.stderr,
                            f"error: missing required tool(s): {tools}\n",
                        )

    def test_a_missing_lib_is_a_clear_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            for tui in TUIS:
                copy = Path(tmp) / tui
                shutil.copy(HERE / tui, copy)
                with self.subTest(tui=tui):
                    result = run_tui(copy, tmp)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    lib = os.path.join(os.path.realpath(tmp), "lib", "tui.sh")
                    self.assertIn(f"{lib} is missing", result.stderr)

    def test_lib_number_and_error_helpers(self):
        # wt is replaced after sourcing, so run_or_report's msgbox text is
        # printed instead of drawn.
        script = r"""
. "$1"
wt() { printf 'MSG[%s]\n' "$2"; }
for v in 08 -007 -0 0 0250 0x10 abc ""; do printf 'n[%s]=%s\n' "$v" "$(normalize_int "$v")"; done
for p in "9223372036854775807 9223372036854775808" "-9223372036854775809 -9223372036854775808" \
	"-1 0" "0 -1" "150 150" "151 150" "99999999999999999999 150" "-20 -3"; do
	set -- $p
	if int_le "$1" "$2"; then r=yes; else r=no; fi
	printf 'le[%s %s]=%s\n' "$1" "$2" "$r"
done
run_or_report "ok failed" true; printf 'rc=%s\n' "$?"
run_or_report "tool failed" sh -c 'echo oops >&2; exit 3'; printf 'rc=%s\n' "$?"
run_or_report "quiet failed" false; printf 'rc=%s\n' "$?"
"""
        result = subprocess.run(
            [BASH, "-c", script, "test", str(LIB)],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "n[08]=8",
                "n[-007]=-7",
                "n[-0]=0",
                "n[0]=0",
                "n[0250]=250",
                "n[0x10]=0x10",
                "n[abc]=abc",
                "n[]=",
                "le[9223372036854775807 9223372036854775808]=yes",
                "le[-9223372036854775809 -9223372036854775808]=yes",
                "le[-1 0]=yes",
                "le[0 -1]=no",
                "le[150 150]=yes",
                "le[151 150]=no",
                "le[99999999999999999999 150]=no",
                "le[-20 -3]=yes",
                "rc=0",
                "MSG[tool failed:\\noops]",
                "rc=3",
                "MSG[quiet failed:\\nexit status 1]",
                "rc=1",
            ],
        )


SYNC = HERE / "sync-root-gtk-theme.sh"
# Tools sync-root-gtk-theme.sh needs to reach its exit points below.
SYNC_TOOLS = ("dirname", "readlink", "realpath", "sort", "basename", "sed", "head")
# A stand-in lib that records being sourced, so a run shows whether it was.
MARKER_LIB = """readonly PROG="${0##*/}"
: >"$TUI_LIB_SOURCED"
die() { printf 'error: %s\\n' "$1" >&2; exit 1; }
require_tools() { :; }
wt() { :; }
"""


def run_sync(script, workdir, *args):
    """Run sync-root-gtk-theme.sh as the current (non-root) user, with a PATH
    that has no sudo and no whiptail, so --check/--apply stop at the root
    hint and --pick stops at its whiptail check -- nothing privileged or
    interactive ever runs."""
    bindir = Path(workdir) / "bin"
    bindir.mkdir(exist_ok=True)
    for tool in SYNC_TOOLS:
        link = bindir / tool
        if not link.exists():
            link.symlink_to(shutil.which(tool))
    return subprocess.run(
        [BASH, str(script), *args],
        check=False,
        cwd=workdir,
        env={
            "PATH": str(bindir),
            "HOME": str(workdir),
            "KARTIK_HOME": str(workdir),
            "TUI_LIB_SOURCED": str(Path(workdir) / "sourced"),
        },
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=20,
    )


class SyncRootGtkThemeTests(unittest.TestCase):
    """sync-root-gtk-theme.sh runs its --check/--apply paths as root, so it
    must reuse lib/tui.sh's wt() (no copy of its own) and source that
    kartik-writable file only on --pick, which runs as kartik."""

    def test_no_own_copy_of_the_shared_helpers(self):
        text = SYNC.read_text()
        for name in SHARED:
            own = re.search(rf"(?m)^\s*{name}\(\)", text)
            self.assertIsNone(own, f"sync-root-gtk-theme.sh defines its own {name}()")

    def test_lib_is_sourced_only_inside_the_pick_arm(self):
        lines = SYNC.read_text().splitlines()
        sources = [
            i
            for i, line in enumerate(lines)
            if re.match(r'\s*(\.|source)\s+"?\$\{?_?tui_lib', line)
        ]
        self.assertTrue(sources, "sync-root-gtk-theme.sh never sources lib/tui.sh")
        start = next(i for i, line in enumerate(lines) if line == "pick)")
        end = next(i for i in range(start, len(lines)) if lines[i] == "\t;;")
        for i in sources:
            self.assertTrue(
                start < i < end,
                f"line {i + 1} sources lib/tui.sh outside the pick) arm",
            )

    def test_only_pick_sources_the_lib_at_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / SYNC.name
            shutil.copy(SYNC, copy)
            (Path(tmp) / "lib").mkdir()
            (Path(tmp) / "lib" / "tui.sh").write_text(MARKER_LIB)
            sourced = Path(tmp) / "sourced"
            for args in (["--check"], ["--apply"], ["--list"], ["--help"]):
                with self.subTest(args=args):
                    run_sync(copy, tmp, *args)
                    self.assertFalse(sourced.exists(), f"{args} sourced lib/tui.sh")
            result = run_sync(copy, tmp, "--pick")
            self.assertTrue(sourced.exists(), "--pick didn't source lib/tui.sh")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("needs whiptail", result.stderr)

    def test_a_missing_lib_only_stops_pick(self):
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / SYNC.name
            shutil.copy(SYNC, copy)
            lib = os.path.join(os.path.realpath(tmp), "lib", "tui.sh")
            result = run_sync(copy, tmp, "--pick")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(f"{lib} is missing", result.stderr)
            result = run_sync(copy, tmp, "--check")
            self.assertNotIn("is missing", result.stderr)
            self.assertIn("needs root", result.stderr)


if __name__ == "__main__":
    unittest.main()
