#!/usr/bin/env python3
# Flags markdown cross-references to local files that don't exist -- the
# class of break a rename/delete leaves behind without a linter catching it.
# Three kinds of reference are checked:
#   - inline links and images, [text](target), including an <angle bracket>
#     target and a trailing "title";
#   - reference definitions, [label]: target (not footnotes, [^1]: ...);
#   - backtick paths in prose, like `docs/foo.md`.
# Link and definition targets resolve the way GitHub renders them: against
# the linking file's own directory, or the repo root for a /leading-slash
# target. They're URL-decoded first (%20 is a space); a URL, a mail link or
# a bare #anchor isn't a local file, so it's skipped. A backtick path is
# prose, not a link, so it may be relative to the repo root, the file's
# directory, or -- in a skill under .claude/skills/<name>/ -- the skill's
# own root, which is what skill files mean by `references/x.md`. Only
# multi-segment backtick paths count: bare filenames like "SKILL.md" or
# "CHANGELOG.md" are generic terms in this repo's prose, not literal
# single-file references, so they're deliberately not checked.
# A target that's gitignored (e.g. java-calculator/, referenced from
# docs/handoff.md as cross-host continuity notes) is also skipped: it's
# deliberately absent from this checkout, not a broken link.
# With --index (the pre-commit hook), the files and their targets both come
# from the git index -- what the commit will contain -- not the working
# tree: a target inside the repo must be in the index, so a link to a file
# that was never git-added fails, and a file is checked as staged. Without
# it (the full sweep and CI), it's the working tree. A target outside the
# repo can't be in any commit, so it's always looked for on disk -- next to
# the real checkout given as --real-root, when this copy runs from the
# pre-commit hook's temporary export of the index rather than in place.
# Usage: check-markdown-links.py [--index] [--real-root DIR] <file.md> ...,
# with paths relative to the repo root.
import os
import re
import subprocess
import sys
from urllib.parse import unquote

BACKTICK_MD = re.compile(r"`([A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_.-]*\.md)`")
# The target is <anything but angle brackets>, or a run of non-space
# characters with at most one level of balanced parentheses; then an
# optional "title", 'title' or (title).
INLINE_LINK = re.compile(
    r"\]\(\s*(?:<([^<>\n]*)>|((?:[^\s()<>]|\([^\s()<>]*\))+))"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^()]*\)))?\s*\)"
)
REF_DEF = re.compile(r"^ {0,3}\[(?!\^)[^\]]+\]:\s*(?:<([^<>\n]*)>|(\S+))")
SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
# A fenced code block opens with 3+ backticks or tildes (an info string may
# follow, but not a backtick after backticks) and closes with a run of the
# same character at least as long, as CommonMark has it. Leading spaces and
# blockquote markers are allowed either way, so a fence in a list item or a
# quote counts too.
FENCE_OPEN = re.compile(r"^[ \t>]*(`{3,}|~{3,})(.*)$")
FENCE_CLOSE = re.compile(r"^[ \t>]*(`{3,}|~{3,})[ \t]*$")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
SKILLS_DIR = (".claude", "skills")
LINK = "link"  # inline links and definitions
PROSE = "prose"  # backtick paths


def local_target(raw):
    # The local path a link target names, or None for a URL, a mail link or
    # a bare #anchor.
    if raw.startswith("//") or SCHEME.match(raw):
        return None
    return unquote(raw.split("#", 1)[0].split("?", 1)[0]) or None


def candidates(line, in_code=False):
    # (target, LINK or PROSE) for every reference on the line. Inside a
    # fenced code block (in_code) and inside an inline code span there are
    # no links -- `[ERROR]: timeout` in a log or fns[i](arg) in JavaScript is
    # just code -- so only backtick paths are looked for there: those are
    # deliberate file references, in a shell example as much as in prose.
    for m in BACKTICK_MD.finditer(line):
        yield m.group(1), PROSE
    if in_code:
        return
    masked = CODE_SPAN.sub(lambda m: " " * len(m.group(0)), line)
    for regex in (INLINE_LINK, REF_DEF):
        for m in regex.finditer(masked):
            raw = m.group(1) if m.group(1) is not None else m.group(2)
            target = local_target(raw)
            if target:
                yield target, LINK


def possible_paths(repo_root, rel_file, target, kind):
    file_dir = os.path.join(repo_root, os.path.dirname(rel_file))
    if kind == LINK:
        if target.startswith("/"):
            return [os.path.join(repo_root, target.lstrip("/"))]
        return [os.path.join(file_dir, target)]
    paths = [os.path.join(repo_root, target), os.path.join(file_dir, target)]
    parts = rel_file.replace(os.sep, "/").split("/")
    if len(parts) > 3 and tuple(parts[:2]) == SKILLS_DIR:
        paths.append(os.path.join(repo_root, *parts[:3], target))
    return paths


def is_gitignored(repo_root, path):
    # A gitignored target is deliberately absent from this checkout (e.g.
    # cross-host reference material like java-calculator/), not a broken
    # link -- don't flag it. Best-effort: if git itself isn't available,
    # treat nothing as ignored rather than erroring the whole check.
    try:
        result = subprocess.run(
            ["git", "check-ignore", "-q", path],
            cwd=repo_root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except OSError:
        return False


def indexed_paths(repo_root):
    # Every path in the git index, plus every directory above one, so a
    # link to a directory resolves too. None if git can't list it. Honours
    # GIT_INDEX_FILE, which git sets for a hook run by `git commit <paths>`.
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=repo_root,
            capture_output=True,
            check=False,
        )
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
    # On disk, or (index mode) in the index. A path outside the repo can't
    # be in a commit at all, so it's still checked on disk -- relative to
    # real_root, the actual checkout, when repo_root is only an export.
    try:
        rel = os.path.relpath(path, repo_root)
    except ValueError:  # Windows: a different drive
        return os.path.exists(path)
    outside = rel == os.pardir or rel.startswith(os.pardir + os.sep)
    if outside and real_root:
        return os.path.exists(os.path.join(real_root, rel))
    if index is None or outside:
        return os.path.exists(path)
    if rel == os.curdir:
        return True
    return rel.replace(os.sep, "/") in index


def read_text(repo_root, rel_file, index):
    # (text, None) for the file's text -- from disk, or (index mode) its
    # staged copy -- or (None, why) when it can't be checked: not in the
    # index, or not valid UTF-8.
    if index is None:
        with open(os.path.join(repo_root, rel_file), "rb") as fh:
            data = fh.read()
    else:
        result = subprocess.run(
            ["git", "cat-file", "blob", ":0:" + rel_file.replace(os.sep, "/")],
            cwd=repo_root,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return None, "not in the git index -- stage it, or check it without --index"
        data = result.stdout
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as err:
        return None, f"not valid UTF-8 (byte {err.start})"
    # Universal newlines, as text-mode open() would give.
    return text.replace("\r\n", "\n").replace("\r", "\n"), None


def check(repo_root, files, index=None, real_root=None):
    # (broken, unreadable): (file, line, target) triples, and (file, why)
    # pairs for files that couldn't be checked at all.
    broken = []
    unreadable = []
    for f in files:
        rel_file = os.path.normpath(
            os.path.relpath(f, repo_root) if os.path.isabs(f) else f
        )
        text, why = read_text(repo_root, rel_file, index)
        if text is None:
            unreadable.append((f, why))
            continue
        fence = None  # (character, length) of the open fence, if any
        for lineno, line in enumerate(text.split("\n"), start=1):
            if fence is None:
                m = FENCE_OPEN.match(line)
                if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                    fence = (m.group(1)[0], len(m.group(1)))
                    continue
            else:
                m = FENCE_CLOSE.match(line)
                if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1]:
                    fence = None
                    continue
            for target, kind in candidates(line, in_code=fence is not None):
                paths = possible_paths(repo_root, rel_file, target, kind)
                if any(present(repo_root, index, p, real_root) for p in paths):
                    continue
                if any(is_gitignored(repo_root, p) for p in paths):
                    continue
                broken.append((f, lineno, target))
    return broken, unreadable


if __name__ == "__main__":
    usage = "usage: check-markdown-links.py [--index] [--real-root DIR] <file.md> ..."
    args, use_index, real_root = [], False, None
    argv = iter(sys.argv[1:])
    for a in argv:
        if a == "--index":
            use_index = True
        elif a == "--real-root":
            real_root = next(argv, None)
            if not real_root:
                print(usage, file=sys.stderr)
                sys.exit(2)
        elif a.startswith("--real-root="):
            real_root = a.split("=", 1)[1]
        else:
            args.append(a)
    if not args:
        print(usage, file=sys.stderr)
        sys.exit(2)

    repo_root = os.path.dirname(os.path.abspath(__file__))
    index = None
    if use_index:
        index = indexed_paths(repo_root)
        if index is None:
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
