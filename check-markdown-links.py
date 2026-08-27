#!/usr/bin/env python3
# Flags markdown cross-references to local files that don't exist on disk —
# the class of break a rename/delete leaves behind without a linter catching it.
# Only matches multi-segment paths (e.g. "docs/foo.md"); bare filenames like
# "SKILL.md" or "CHANGELOG.md" are generic terms in this repo's prose, not
# literal single-file references, so they're deliberately not checked.
# A target that's gitignored (e.g. java-calculator/, referenced from
# docs/handoff.md as cross-host continuity notes) is also skipped: it's
# deliberately absent from this checkout, not a broken link.
import os
import re
import subprocess
import sys

BACKTICK_MD = re.compile(r'`([A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_.-]*\.md)`')
MD_LINK = re.compile(r'\]\(([^)\s]+)\)')


def candidates(line):
    for m in BACKTICK_MD.finditer(line):
        yield m.group(1)
    for m in MD_LINK.finditer(line):
        target = m.group(1)
        if target.startswith(('http://', 'https://', 'mailto:', '#')):
            continue
        yield target.split('#')[0]


def is_gitignored(repo_root, path):
    # A gitignored target is deliberately absent from this checkout (e.g.
    # cross-host reference material like java-calculator/), not a broken
    # link -- don't flag it. Best-effort: if git itself isn't available,
    # treat nothing as ignored rather than erroring the whole check.
    try:
        result = subprocess.run(
            ['git', 'check-ignore', '-q', path],
            cwd=repo_root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0
    except OSError:
        return False


def check(repo_root, files):
    broken = []
    for f in files:
        path = os.path.join(repo_root, f)
        file_dir = os.path.dirname(path)
        with open(path, encoding='utf-8') as fh:
            for lineno, line in enumerate(fh, start=1):
                for target in candidates(line):
                    root_relative = os.path.join(repo_root, target)
                    file_relative = os.path.join(file_dir, target)
                    if os.path.exists(root_relative) or os.path.exists(file_relative):
                        continue
                    if is_gitignored(repo_root, root_relative) or is_gitignored(repo_root, file_relative):
                        continue
                    broken.append((f, lineno, target))
    return broken


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: check-markdown-links.py <file.md> [file.md ...]', file=sys.stderr)
        sys.exit(2)

    repo_root = os.path.dirname(os.path.abspath(__file__))
    broken = check(repo_root, sys.argv[1:])
    for f, lineno, target in broken:
        print(f'{f}:{lineno}: broken reference to {target}')
    sys.exit(1 if broken else 0)
