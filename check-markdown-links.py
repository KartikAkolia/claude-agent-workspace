#!/usr/bin/env python3
# Flags markdown links, reference definitions and multi-segment `backtick/paths.md` that name
# missing local files (gitignored targets are skipped). --index reads files and targets from the
# git index; --real-root is where targets outside the repo are looked for.
import os
import re
import subprocess
import sys
from urllib.parse import unquote

BACKTICK_MD = re.compile(r"`([A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_.-]*\.md)`")
INLINE_LINK = re.compile(
    r"\]\(\s*(?:<([^<>\n]*)>|((?:[^\s()<>]|\([^\s()<>]*\))+))"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^()]*\)))?\s*\)"
)
REF_DEF = re.compile(r"^ {0,3}\[(?!\^)[^\]]+\]:\s*(?:<([^<>\n]*)>|(\S+))")
SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
FENCE_OPEN = re.compile(r"^[ \t>]*(`{3,}|~{3,})(.*)$")
FENCE_CLOSE = re.compile(r"^[ \t>]*(`{3,}|~{3,})[ \t]*$")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
SKILLS_DIR = (".claude", "skills")
LINK = "link"
PROSE = "prose"
USAGE = "usage: check-markdown-links.py [--index] [--real-root DIR] <file.md> ..."


def local_target(raw):
    if raw.startswith("//") or SCHEME.match(raw):
        return None
    return unquote(raw.split("#", 1)[0].split("?", 1)[0]) or None


def candidates(line, in_code=False):
    for m in BACKTICK_MD.finditer(line):
        yield m.group(1), PROSE
    if in_code:
        return
    masked = CODE_SPAN.sub(lambda m: " " * len(m.group(0)), line)
    matches = [*INLINE_LINK.finditer(masked), *REF_DEF.finditer(masked)]
    raws = (m.group(1) if m.group(1) is not None else m.group(2) for m in matches)
    yield from ((target, LINK) for target in map(local_target, raws) if target)


def code_lines(text):
    fence = None
    for lineno, line in enumerate(text.split("\n"), start=1):
        m = (FENCE_OPEN if fence is None else FENCE_CLOSE).match(line)
        run = m.group(1) if m else ""
        if run and fence is None and not (run[0] == "`" and "`" in m.group(2)):
            fence = (run[0], len(run))
        elif run and fence is not None and run[0] == fence[0] and len(run) >= fence[1]:
            fence = None
        else:
            yield lineno, line, fence is not None


def possible_paths(repo_root, rel_file, target, kind):
    file_dir = os.path.join(repo_root, os.path.dirname(rel_file))
    if kind == LINK:
        base = repo_root if target.startswith("/") else file_dir
        return [os.path.join(base, target.lstrip("/"))]
    paths = [os.path.join(repo_root, target), os.path.join(file_dir, target)]
    parts = rel_file.replace(os.sep, "/").split("/")
    if len(parts) > 3 and tuple(parts[:2]) == SKILLS_DIR:
        paths.append(os.path.join(repo_root, *parts[:3], target))
    return paths


def git(repo_root, *args, **kwargs):
    return subprocess.run(["git", *args], cwd=repo_root, check=False, **kwargs)


def is_gitignored(repo_root, path):
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    try:
        return git(repo_root, "check-ignore", "-q", path, **quiet).returncode == 0
    except OSError:
        return False


def indexed_paths(repo_root):
    try:
        result = git(repo_root, "ls-files", "-z", capture_output=True)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    paths = set()
    for raw in result.stdout.split(b"\0"):
        path = os.fsdecode(raw)
        while path and path not in paths:
            paths.add(path)
            path = os.path.dirname(path)
    return paths


def present(repo_root, index, path, real_root=None):
    try:
        rel = os.path.relpath(path, repo_root)
    except ValueError:
        return os.path.exists(path)
    outside = rel == os.pardir or rel.startswith(os.pardir + os.sep)
    if outside and real_root:
        return os.path.exists(os.path.join(real_root, rel))
    if index is None or outside:
        return os.path.exists(path)
    return rel == os.curdir or rel.replace(os.sep, "/") in index


def resolves(repo_root, rel_file, target, kind, index, real_root):
    paths = possible_paths(repo_root, rel_file, target, kind)
    if any(present(repo_root, index, p, real_root) for p in paths):
        return True
    return any(is_gitignored(repo_root, p) for p in paths)


def read_text(repo_root, rel_file, index):
    if index is None:
        with open(os.path.join(repo_root, rel_file), "rb") as fh:
            data = fh.read()
    else:
        blob = ":0:" + rel_file.replace(os.sep, "/")
        result = git(repo_root, "cat-file", "blob", blob, capture_output=True)
        data = result.stdout if result.returncode == 0 else None
    if data is None:
        return None, "not in the git index -- stage it, or check it without --index"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as err:
        return None, f"not valid UTF-8 (byte {err.start})"
    return text.replace("\r\n", "\n").replace("\r", "\n"), None


def check(repo_root, files, index=None, real_root=None):
    broken, unreadable = [], []
    for f in files:
        rel_file = os.path.relpath(f, repo_root) if os.path.isabs(f) else f
        rel_file = os.path.normpath(rel_file)
        text, why = read_text(repo_root, rel_file, index)
        if text is None:
            unreadable.append((f, why))
            continue
        broken += [
            (f, lineno, target)
            for lineno, line, in_code in code_lines(text)
            for target, kind in candidates(line, in_code)
            if not resolves(repo_root, rel_file, target, kind, index, real_root)
        ]
    return broken, unreadable


args, use_index, real_root, bad_usage = [], False, None, False
argv = iter(sys.argv[1:])
for a in argv:
    if a == "--index":
        use_index = True
    elif a == "--real-root":
        real_root = next(argv, None)
        bad_usage = bad_usage or not real_root
    elif a.startswith("--real-root="):
        real_root = a.split("=", 1)[1]
    else:
        args.append(a)
if bad_usage or not args:
    print(USAGE, file=sys.stderr)
    sys.exit(2)

repo_root = os.path.dirname(os.path.abspath(__file__))
index = indexed_paths(repo_root) if use_index else None
if use_index and index is None:
    print(
        "check-markdown-links: could not read the git index (git ls-files failed)",
        file=sys.stderr,
    )
    sys.exit(2)
broken, unreadable = check(repo_root, args, index, real_root)
for f, why in unreadable:
    print(f"{f}: {why}")
for f, lineno, target in broken:
    print(f"{f}:{lineno}: broken reference to {target}")
sys.exit(1 if broken or unreadable else 0)
