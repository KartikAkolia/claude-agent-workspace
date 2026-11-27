#!/usr/bin/env python3
"""lib/tui.sh wiring for the whiptail TUIs and sync-root-gtk-theme.sh."""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
LIB = SCRIPTS / "lib" / "tui.sh"
TUI_DIR = SCRIPTS / "desktop-tuis"
TUIS = {
    "audio-tui.sh": "whiptail pactl jq",
    "display-tui.sh": "whiptail xrandr awk mktemp rm",
    "webcam-tui.sh": "whiptail v4l2-ctl awk grep",
}
TUI_TOOLS = ("dirname", "readlink")
SHARED = ("wt", "die", "require_tools")
INTERFACE = (*SHARED, "pick_menu", "run_or_report", "normalize_int", "int_le")
LIB_FUNCS = re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\) \{$", LIB.read_text())
BASH = shutil.which("bash")
SYNC = SCRIPTS / "gtk-root-theme" / "sync-root-gtk-theme.sh"
SYNC_TOOLS = ("dirname", "readlink", "realpath", "sort", "basename", "sed", "head")
MARKER_LIB = """readonly PROG="${0##*/}"
: >"$TUI_LIB_SOURCED"
die() { printf 'error: %s\\n' "$1" >&2; exit 1; }
require_tools() { :; }
wt() { :; }
"""


def run_script(script, workdir, tools, *args):
    bindir = Path(workdir) / "bin"
    bindir.mkdir(exist_ok=True)
    for tool in tools:
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


class TuiLibTests(unittest.TestCase):
    def test_shared_helpers_live_only_in_the_lib(self):
        for name in INTERFACE:
            self.assertIn(name, LIB_FUNCS, f"lib/tui.sh doesn't define {name}()")
        self.assertRegex(LIB.read_text(), r"(?m)^readonly PROG=", "lib sets no PROG")
        own_func = rf"(?m)^({'|'.join(LIB_FUNCS)})\(\)"
        for tui in TUIS:
            text = (TUI_DIR / tui).read_text()
            with self.subTest(tui=tui):
                self.assertNotRegex(text, own_func, f"{tui} defines a lib function")
                self.assertNotRegex(text, r"(?m)^readonly PROG=", f"{tui} sets PROG")
                self.assertRegex(text, r'(?m)^tui_lib=.*/lib/tui\.sh"$', "no lib path")
                self.assertRegex(text, r'(?m)^\. "\$tui_lib"$', "lib not sourced")

    def test_lib_is_found_from_the_repo_and_through_a_symlink(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        cases = []
        for tui, tools in TUIS.items():
            (tmp / f"link-{tui}").symlink_to(TUI_DIR / tui)
            cases += [(TUI_DIR / tui, tools), (tmp / f"link-{tui}", tools)]
        for script, tools in cases:
            with self.subTest(script=str(script)):
                result = run_script(script, tmp, TUI_TOOLS)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(
                    result.stderr, f"error: missing required tool(s): {tools}\n"
                )

    def test_a_missing_lib_is_a_clear_error(self):
        tmp = self.enterContext(tempfile.TemporaryDirectory())
        lib = os.path.join(os.path.realpath(tmp), "lib", "tui.sh")
        for tui in TUIS:
            copy = Path(tmp) / TUI_DIR.name / tui
            copy.parent.mkdir(exist_ok=True)
            shutil.copy(TUI_DIR / tui, copy)
            with self.subTest(tui=tui):
                result = run_script(copy, tmp, TUI_TOOLS)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"{lib} is missing", result.stderr)

    def test_lib_number_and_error_helpers(self):
        script = r"""
. "$1"
unset PICK RC
wt() {
	[ "$1" = --menu ] || {
		printf 'MSG[%s]\n' "$2"
		return
	}
	printf '%s' "${PICK-$*}" >&2
	return "${RC:-0}"
}
pick_menu T "nothing to pick"; printf 'rc=%s\n' "$?"
r=$(pick_menu T E a A b B); printf 'pick[%s]=%s\n' "$r" "$?"
r=$(PICK=b pick_menu T E a A b B); printf 'pick[%s]=%s\n' "$r" "$?"
r=$(PICK= pick_menu T E a A); printf 'pick[%s]=%s\n' "$r" "$?"
r=$(PICK=a RC=1 pick_menu T E a A); printf 'pick[%s]=%s\n' "$r" "$?"
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
                "MSG[nothing to pick]",
                "rc=1",
                "pick[--menu T 0 0 0 a A b B]=0",
                "pick[b]=0",
                "pick[]=1",
                "pick[]=1",
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


class SyncRootGtkThemeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.copy = self.tmp / SYNC.parent.name / SYNC.name
        self.copy.parent.mkdir()
        shutil.copy(SYNC, self.copy)

    def test_no_own_copy_of_the_shared_helpers(self):
        text = SYNC.read_text()
        for name in SHARED:
            self.assertNotRegex(text, rf"(?m)^\s*{name}\(\)", f"defines its own {name}")

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
        (self.tmp / "lib").mkdir()
        (self.tmp / "lib" / "tui.sh").write_text(MARKER_LIB)
        sourced = self.tmp / "sourced"
        for args in (["--check"], ["--apply"], ["--list"], ["--help"]):
            with self.subTest(args=args):
                run_script(self.copy, self.tmp, SYNC_TOOLS, *args)
                self.assertFalse(sourced.exists(), f"{args} sourced lib/tui.sh")
        result = run_script(self.copy, self.tmp, SYNC_TOOLS, "--pick")
        self.assertTrue(sourced.exists(), "--pick didn't source lib/tui.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("needs whiptail", result.stderr)

    def test_a_missing_lib_only_stops_pick(self):
        lib = os.path.join(os.path.realpath(self.tmp), "lib", "tui.sh")
        result = run_script(self.copy, self.tmp, SYNC_TOOLS, "--pick")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"{lib} is missing", result.stderr)
        result = run_script(self.copy, self.tmp, SYNC_TOOLS, "--check")
        self.assertNotIn("is missing", result.stderr)
        self.assertIn("needs root", result.stderr)


if __name__ == "__main__":
    unittest.main()
