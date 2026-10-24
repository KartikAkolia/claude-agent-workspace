#!/usr/bin/env python3
"""Literal GRUB editing and effective module checks for the power policy script."""

import re
import shlex
import sys
from pathlib import Path

PARAMS = {
    "usbcore.autosuspend": "-1",
    "pcie_aspm.policy": "performance",
    "nvme_core.default_ps_max_latency_us": "0",
}
ASSIGNMENT = re.compile(r"^\s*(?:export\s+)?GRUB_CMDLINE_LINUX_DEFAULT\s*=")
LITERAL = re.compile(
    r"^(\s*(?:export\s+)?GRUB_CMDLINE_LINUX_DEFAULT\s*=\s*)([\"'])(.*)\2([ \t]*(?:#.*)?)$"
)


def read_grub(text):
    lines = text.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if ASSIGNMENT.match(line)]
    if len(matches) != 1:
        raise ValueError("require exactly one GRUB_CMDLINE_LINUX_DEFAULT assignment")
    index = matches[0]
    match = LITERAL.fullmatch(lines[index].rstrip("\n"))
    if not match:
        raise ValueError("GRUB command line must be a single quoted literal line")
    prefix, quote, value, suffix = match.groups()
    if any(c in value for c in "\\$`\"'"):
        raise ValueError(
            "GRUB expansions, escapes and embedded quotes need manual editing"
        )
    if "--" in value.split():
        raise ValueError(
            "GRUB command line contains --; edit kernel/init arguments manually"
        )
    return lines, index, prefix, quote, value.split(), suffix


def managed(tokens):
    return [t for t in tokens if t.split("=", 1)[0] in PARAMS]


def grub(text, before=None):
    lines, index, prefix, quote, tokens, suffix = read_grub(text)
    replacement = [f"{key}={value}" for key, value in PARAMS.items()]
    if before is not None:
        if sorted(managed(tokens)) != sorted(replacement):
            raise ValueError(
                "managed GRUB parameters changed since install; undo manually"
            )
        old_tokens = read_grub(before)[4]
        replacement = managed(old_tokens)
    tokens = [t for t in tokens if t.split("=", 1)[0] not in PARAMS] + replacement
    lines[index] = f"{prefix}{quote}{' '.join(tokens)}{quote}{suffix}\n"
    return "".join(lines)


def modules(text):
    expected = {
        ("snd_hda_intel", "power_save"): "0",
        ("snd_hda_intel", "power_save_controller"): "n",
        ("nvidia", "NVreg_DynamicPowerManagement"): "0",
        ("iwlmvm", "power_scheme"): "1",
    }
    effective = {}
    for line in text.splitlines():
        if not re.match(r"^options\s", line):
            continue
        fields = shlex.split(line, comments=True)
        if len(fields) < 3 or fields[0] != "options":
            continue
        for token in fields[2:]:
            key, _, value = token.partition("=")
            effective[(fields[1].replace("-", "_"), key)] = value
    for key, wanted in expected.items():
        value = effective.get(key, "").lower()
        if wanted == "n":
            valid = value in ("n", "no", "0", "false")
        else:
            try:
                valid = int(value, 16 if value.startswith("0x") else 10) == int(wanted)
            except ValueError:
                valid = False
        if not valid:
            raise ValueError(
                f"effective {key[0]}.{key[1]}={value!r}, expected {wanted}; "
                "resolve modprobe.d or kernel-command-line conflicts and rerun"
            )


def boot(text):
    checked = 0
    for line in text.splitlines():
        if not re.match(r"^\s*linux(?:efi|16)?\s", line):
            continue
        tokens = shlex.split(line, comments=True)[2:]
        if any(
            t
            in (
                "single",
                "recovery",
                "systemd.unit=rescue.target",
                "systemd.unit=emergency.target",
            )
            for t in tokens
        ):
            continue
        effective = dict(t.split("=", 1) for t in tokens if "=" in t)
        if any(effective.get(key) != value for key, value in PARAMS.items()):
            raise ValueError(
                "generated GRUB entry lacks the requested policy; check GRUB overrides"
            )
        checked += 1
    if not checked:
        raise ValueError("no verifiable normal Linux entry in generated grub.cfg")


def main():
    operation, *args = sys.argv[1:]
    if operation == "boot":
        boot(sys.stdin.read())
    elif operation == "modules":
        modules(sys.stdin.read())
    elif operation == "grub":
        print(grub(Path(args[0]).read_text()), end="")
    elif operation == "undo-grub":
        print(grub(Path(args[0]).read_text(), Path(args[1]).read_text()), end="")
    else:
        raise ValueError("unknown operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(f"error: {error}")
