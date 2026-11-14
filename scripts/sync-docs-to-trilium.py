#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown>=3.6"]
# ///
"""Mirror this repo's Markdown docs into Trilium as read-only text notes.

Each Markdown file becomes one text note (Markdown rendered to HTML) under a
single parent note, "claude-agent-workspace docs", and each directory becomes
a folder note. Notes are matched to files by a `workspaceDocPath` label, not by
title, so re-running the script updates notes in place. Every doc is rendered
on each run, and its note is only rewritten when the final HTML (including
resolved links) differs from what was last written (`workspaceDocHash`), so
unchanged docs don't pile up revisions. Relative Markdown links between synced
docs become Trilium internal links; other relative Markdown links and images
can't resolve in Trilium and are reported. Links inside raw HTML blocks are
left as they are and not reported. Use a leading / for repo-root links;
other paths are relative to the document.

The repo is the source of truth: doc notes carry `#readOnly`, and any edit made
in Trilium is overwritten the next time that doc's rendering changes. Notes for
files deleted from the repo are listed, and only removed with --prune. A stale
folder note is only pruned when every note under it is a stale doc too.
Protected notes are skipped with a warning, never written or pruned, since
ETAPI can't open a protected session.

Only files git tracks (or would track) are synced, so gitignored nested repos
(estuary/, personal-website/, ...) never leave the machine. Hidden directories
and the read-only reference clones are skipped too.

Token: TRILIUM_ETAPI_TOKEN, or the file ~/.config/trilium-etapi-token
(Trilium -> Options -> ETAPI -> Create new token). URL: --url or TRILIUM_URL.

Usage:
    scripts/sync-docs-to-trilium.py [--dry-run] [--prune] [PATH ...]
PATH is a file or folder relative to the current directory, inside the repo.
With no PATH, the repo's docs/ folder is synced.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import html as htmllib
import http.client
import json
import os
import posixpath
import re
import secrets
import string
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import markdown
from markdown.treeprocessors import Treeprocessor

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_URL = "https://trilium.kartikpassbolt.org"
TOKEN_FILE = Path.home() / ".config" / "trilium-etapi-token"
ROOT_LABEL = "workspaceDocsRoot"
PATH_LABEL = "workspaceDocPath"
HASH_LABEL = "workspaceDocHash"
ROOT_TITLE = "claude-agent-workspace docs"


def reference_clone_table() -> list[tuple[str, str, str]]:
    """(dir, owner/repo, branch) for each of ChrisTitusTech's read-only
    reference clones (AGENTS.md), as `list-lint-files.sh --reference-clones`
    prints them. That script is the one parser of reference-clones.tsv --
    the lint gates and refresh-reference-clone.sh use it too -- so its rules
    exist once. A missing or malformed list, or no bash to run it, stops the
    run with the lister's own message rather than letting a clone through."""
    lister = REPO_ROOT / "list-lint-files.sh"
    try:
        result = subprocess.run(
            ["bash", str(lister), "--reference-clones"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as err:
        sys.exit(f"Can't read the reference-clone list: can't run bash: {err}")
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        sys.exit(f"Can't read the reference-clone list: {detail}")
    table = []
    for line in result.stdout.splitlines():
        fields = tuple(line.split("\t"))
        if len(fields) != 3 or not all(fields):
            sys.exit(f"Can't read the reference-clone list: unexpected line {line!r}")
        table.append(fields)
    if not table:
        sys.exit("Can't read the reference-clone list: list-lint-files.sh printed none")
    return table


@functools.cache
def reference_clones() -> frozenset[str]:
    """The reference clones' directory names (see reference_clone_table)."""
    names = [clone for clone, _, _ in reference_clone_table()]
    missing = [n for n in names if not (REPO_ROOT / n).is_dir()]
    if missing:
        print(f"warning: reference clones not on disk: {', '.join(missing)}")
    return frozenset(names)


FRONT_MATTER = re.compile(
    r"\A---[ \t]*\n(?:(.*?)\n)?(?:---|\.\.\.)[ \t]*(?:\n|\Z)", re.DOTALL
)
LEADING_COMMENTS = re.compile(r"\A(?:\s*<!--.*?-->)*", re.DOTALL)
ATX_H1 = re.compile(
    r"\A(?:[ \t]*\n)*[ ]{0,3}#(?!#)[ \t]*(.+?)(?:[ \t]+#+)?[ \t]*(?:\n|\Z)"
)
SETEXT_H1 = re.compile(r"\A(?:[ \t]*\n)*[ ]{0,3}(\S[^\n]*?)[ \t]*\n=+[ \t]*(?:\n|\Z)")


class EtapiError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status  # the HTTP status, when the server answered

    @property
    def refused(self) -> bool:
        """The server answered and didn't act (3xx/4xx), as opposed to a
        5xx or lost response, where the request may have gone through."""
        return self.status is not None and self.status < 500


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse redirects: urllib would replay the Authorization header (the
    ETAPI token) to whatever host a redirect names."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise EtapiError(
            f"{req.get_method()} {req.full_url}: redirected to {newurl}", code
        )


OPENER = urllib.request.build_opener(NoRedirect)
ID_CHARS = string.ascii_letters + string.digits


def new_note_id() -> str:
    """A random noteId shaped like Trilium's own (12 letters and digits)."""
    return "".join(secrets.choice(ID_CHARS) for _ in range(12))


class Etapi:
    def __init__(self, base_url: str, token: str, dry_run: bool) -> None:
        self.base = base_url.rstrip("/") + "/etapi"
        self.token = token
        self.dry_run = dry_run
        self.fake_ids = 0

    def call(self, method: str, path: str, body=None, raw_text: bool = False):
        if self.dry_run and method != "GET":
            print(f"  [dry-run] {method} {path}")
            self.fake_ids += 1
            return {"note": {"noteId": f"dryrun{self.fake_ids}"}}
        # Cloudflare's browser integrity check rejects urllib's default
        # User-Agent with error 1010, so name the client explicitly.
        headers = {"Authorization": self.token, "User-Agent": "sync-docs-to-trilium/1"}
        data = None
        if body is not None:
            if raw_text:
                data = body.encode()
                headers["Content-Type"] = "text/plain; charset=utf-8"
            else:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
        try:
            req = urllib.request.Request(
                self.base + path, data=data, method=method, headers=headers
            )
            with OPENER.open(req, timeout=30) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:500]
            raise EtapiError(
                f"{method} {path}: HTTP {err.code}: {detail}", err.code
            ) from err
        # URLError, timeouts, resets and TLS errors are all OSError;
        # IncompleteRead and friends are HTTPException.
        except (OSError, http.client.HTTPException) as err:
            raise EtapiError(f"{method} {path}: {err}") from err
        # http.client rejects a bad header with ValueError('Invalid header
        # value ...') quoting the value, which here is the token, so neither
        # the message nor the chained exception is passed on.
        except ValueError as err:
            raise EtapiError(
                f"{method} {path}: invalid request ({type(err).__name__}, "
                "details withheld as they can quote the token); check the token "
                "and URL"
            ) from None
        if not payload:
            if method in ("GET", "POST"):
                raise EtapiError(f"{method} {path}: empty response")
            return None
        try:
            return json.loads(payload)
        except json.JSONDecodeError as err:
            raise EtapiError(f"{method} {path}: response isn't JSON: {err}") from err

    def search(self, query: str) -> list[dict]:
        """Search the whole tree. Archived notes are included: missing one
        would create a duplicate."""
        params = {"search": query, "limit": "10000", "includeArchivedNotes": "true"}
        results = self.call("GET", "/notes?" + urllib.parse.urlencode(params))[
            "results"
        ]
        if len(results) >= int(params["limit"]):
            raise EtapiError(f"search {query!r} hit the {params['limit']} result cap")
        return results

    def create(self, parent: str, title: str, labels: dict[str, str]) -> str:
        note_id = self.create_note(parent, title)
        # ETAPI can't label a note at creation. A note left without its
        # identifying label is invisible to later runs, so undo the create if
        # labelling fails or is interrupted, without hiding the original error.
        try:
            for name, value in labels.items():
                self.add_label(note_id, name, value)
        except BaseException:
            self.discard(note_id)
            raise
        return note_id

    def create_note(self, parent: str, title: str) -> str:
        """POST create-note with a noteId chosen here (CreateNoteDef accepts
        one), so a create whose response is lost or garbled can be looked up:
        the note is adopted if it exists, rather than left as an unlabelled
        orphan that the next run duplicates. An interrupted create is looked
        up and deleted."""
        note_id = new_note_id()
        body = {"parentNoteId": parent, "title": title, "type": "text", "content": ""}
        try:
            created = self.call("POST", "/create-note", {**body, "noteId": note_id})
        except EtapiError as err:
            if err.refused or not self.was_created(note_id, parent, title):
                raise
            print(
                f"warning: create-note failed ({err}), but note {note_id} "
                f"('{title}') exists; using it",
                file=sys.stderr,
            )
            return note_id
        except BaseException:
            if self.was_created(note_id, parent, title):
                self.discard(note_id)
            raise
        returned = created.get("note") if isinstance(created, dict) else None
        returned = returned.get("noteId") if isinstance(returned, dict) else None
        if isinstance(returned, str) and returned:
            return returned  # note_id, or a dry run's placeholder
        if self.was_created(note_id, parent, title):
            return note_id
        raise EtapiError(f"create-note: unexpected response {created!r}")

    def was_created(self, note_id: str, parent: str, title: str) -> bool:
        """Whether this run's create-note made note_id after all. Only a note
        with the title and parent asked for counts, so a note that already
        had the ID is never adopted or deleted."""
        if self.dry_run:
            return False
        try:
            found = self.call("GET", f"/notes/{note_id}")
        except EtapiError as err:
            if err.status != 404:
                print(
                    f"warning: can't tell whether note {note_id} ('{title}') was "
                    f"created ({err}); if it exists without a {PATH_LABEL} label, "
                    "delete it by hand",
                    file=sys.stderr,
                )
            return False
        return (
            isinstance(found, dict)
            and found.get("title") == title
            and parent in (found.get("parentNoteIds") or [])
        )

    def discard(self, note_id: str) -> None:
        """Delete a note this run created but couldn't finish labelling."""
        if self.dry_run:
            return
        try:
            self.call("DELETE", f"/notes/{note_id}")
        except EtapiError:
            print(
                f"warning: couldn't delete unlabelled note {note_id}; "
                "delete it by hand",
                file=sys.stderr,
            )

    def add_label(self, note_id: str, name: str, value: str = "") -> None:
        self.call(
            "POST",
            "/attributes",
            {"noteId": note_id, "type": "label", "name": name, "value": value},
        )

    def descendants(self, note_id: str) -> list[str]:
        out, todo = [], [note_id]
        while todo:
            children = self.call("GET", f"/notes/{todo.pop()}")["childNoteIds"]
            out += children
            todo += children
        return out


def label(note: dict, name: str) -> dict | None:
    """The note's own label (inherited ones aren't in `attributes`)."""
    return next(
        (a for a in note["attributes"] if a["type"] == "label" and a["name"] == name),
        None,
    )


def rel_path(p: str) -> str:
    """Repo-relative POSIX path of a CLI argument; '' for the repo root."""
    # abspath, not resolve(): a symlinked doc is synced as itself, not as
    # whatever it points to.
    full = Path(os.path.abspath(p))
    if not full.is_relative_to(REPO_ROOT):
        # Resolve the parent when the repo is reached through an alias, but
        # preserve the final component if it is a symlinked document.
        parent_resolved = full.parent.resolve() / full.name
        if parent_resolved.is_relative_to(REPO_ROOT):
            full = parent_resolved
        elif full.is_dir():
            full = full.resolve()  # the alias itself may name the repo root
    if not full.is_relative_to(REPO_ROOT):
        sys.exit(f"{p}: outside the repo")
    rel = full.relative_to(REPO_ROOT).as_posix()
    return "" if rel == "." else rel


def excluded(rel: str) -> bool:
    """Reference clones are top-level folders (reference-clones.tsv);
    hidden folders and node_modules are skipped at any depth."""
    parts = rel.split("/")
    if parts[0] in reference_clones():
        return True
    return any(part.startswith(".") or part == "node_modules" for part in parts)


def syncable_files() -> list[str]:
    """Every Markdown file this script may sync, repo-wide: tracked or
    untracked-but-not-ignored, minus hidden dirs and the reference clones."""
    try:
        listed = (
            subprocess.run(
                [
                    "git",
                    "ls-files",
                    "-z",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                    "--",
                    "*.md",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                check=True,
            )
            .stdout.decode("utf-8", "surrogateescape")
            .split("\0")
        )
    except (OSError, subprocess.CalledProcessError) as err:
        detail = getattr(err, "stderr", b"") or err
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace").strip()
        sys.exit(f"Can't list repo files with git: {detail}")
    # A set: during a merge conflict git lists a path once per stage.
    candidates = {f for f in listed if f and not excluded(f)}
    return sorted(f for f in candidates if publishable(f, candidates))


def in_scope(p: str, scope: list[str]) -> bool:
    return any(s == "" or p == s or p.startswith(s + "/") for s in scope)


def publishable(rel: str, candidates: set[str]) -> bool:
    """A regular file whose real location (after symlinks) is itself a
    syncable repo file, so a symlink can't publish a private file from outside
    the repo, a gitignored nested repo, a hidden folder or a clone."""
    path = REPO_ROOT / rel
    if not path.is_file():
        return False
    real = path.resolve()
    if not real.is_relative_to(REPO_ROOT):
        return False
    return real.relative_to(REPO_ROOT).as_posix() in candidates


def collect_files(paths: list[str], every: list[str]) -> tuple[list[str], list[str]]:
    """Return (files, scope): the Markdown files to sync and the repo-relative
    paths they were collected from."""
    scope = [rel_path(p) for p in paths]
    files = [f for f in every if in_scope(f, scope)]
    for p, s in zip(paths, scope, strict=True):
        if s and excluded(s):
            sys.exit(f"{p}: excluded from syncing (hidden, node_modules or a clone)")
        if (REPO_ROOT / s).is_file() and s not in files:
            sys.exit(f"{p}: not a syncable Markdown file")
    # A deleted path is fine here (its stale notes are listed, or pruned with
    # --prune); a path matching nothing at all is caught after the run.
    return files, scope


def with_parents(files: list[str]) -> set[str]:
    """The files plus every folder above them (not the repo root)."""
    out = set(files)
    for f in files:
        while f := parent_dir(f):
            out.add(f)
    return out


TITLE_MD = markdown.Markdown()


def plain_title(md_title: str) -> str:
    """Strip inline Markdown (code, emphasis, links) from a heading.

    Leading block markers are escaped first, so `# 1. Setup` stays "1. Setup"
    instead of being rendered as a list.
    """
    # "<" is swapped for a private-use character so `<placeholder>` isn't
    # parsed as raw HTML (and stripped), then swapped back at the end.
    escaped = md_title.replace("<", "\ue000")
    escaped = re.sub(r"\A(\d+)([.)])", r"\1\\\2", escaped)
    # List bullets only count when followed by a space; `**Bold**` must survive.
    escaped = re.sub(r"\A([-+*])(?=[ \t])|\A([>#])", r"\\\1\2", escaped)
    html = TITLE_MD.reset().convert(escaped)
    text = htmllib.unescape(re.sub(r"<[^>]+>", "", html))
    return text.replace("\ue000", "<").strip()


def split_title(rel: str, text: str) -> tuple[str, str]:
    """Return (title, body). YAML front matter is dropped (its `title:` is used
    if there's no H1), and a leading H1 becomes the title, not body text."""
    fallback = Path(rel).stem
    fm = FRONT_MATTER.match(text)
    # Only a block made entirely of YAML-looking lines (lowercase `key:`, indented
    # continuations, `- ` items) is front matter; a doc that opens with a
    # `---` rule keeps its first section.
    if fm and all(
        re.match(r"[a-z0-9_-]+:(?:[ \t]|$)|[ \t]|- ", line) or not line.strip()
        for line in (fm.group(1) or "").splitlines()
    ):
        text = text[fm.end() :]
        fm_title = re.search(
            r"^title:[ \t]*(.+?)[ \t]*$", fm.group(1) or "", re.MULTILINE
        )
        if fm_title:
            fallback = fm_title.group(1).strip("\"'")
    # HTML comments (e.g. markdownlint directives) may come before the H1.
    comments = LEADING_COMMENTS.match(text).group(0)
    rest = text[len(comments) :]
    match = ATX_H1.match(rest) or SETEXT_H1.match(rest)
    if match:
        title = plain_title(match.group(1))
        if title:
            body = rest[match.end() :]
            return title, (comments + "\n\n" + body) if comments.strip() else body
    return fallback, text


class LinkRewriter(Treeprocessor):
    """Point links to other synced docs at their Trilium notes.

    Works on the parsed element tree, so `href="..."` text inside code is never
    touched. Raw HTML blocks aren't parsed by Markdown and are left as they are.
    Trilium internal links can't target a heading, so a #fragment is dropped.
    """

    def __init__(self, md, rel: str, note_ids: dict[str, str], unresolved: list[str]):
        super().__init__(md)
        self.rel, self.note_ids, self.unresolved = rel, note_ids, unresolved

    def run(self, root):
        for el in root.iter():
            attr = {"a": "href", "img": "src"}.get(el.tag)
            raw = el.get(attr) if attr else None
            # Skip external (scheme: or protocol-relative //host) and in-page links.
            # \x02 starts Markdown's placeholder for obfuscated mailto links.
            if not raw or re.match(
                r"[a-z][a-z0-9+.-]*:|#|//|\?|\x02", raw, re.IGNORECASE
            ):
                continue
            # Drop ?query and #fragment before decoding, so an encoded %23 or
            # %3F in a file name stays part of the path.
            path = urllib.parse.unquote(re.split(r"[?#]", raw, maxsplit=1)[0])
            href = urllib.parse.unquote(raw)
            # A leading / means repo-root-relative, as GitHub renders it.
            base = "" if path.startswith("/") else posixpath.dirname(self.rel)
            target = posixpath.normpath(posixpath.join(base, path.lstrip("/")))
            target = "" if target == "." else target  # the repo root
            note_id = self.note_ids.get(target) if el.tag == "a" else None
            if note_id:
                el.set("href", f"#root/{note_id}")
            else:
                self.unresolved.append(href)


class Renderer:
    """One Markdown pipeline, reused for every doc."""

    def __init__(self, note_ids: dict[str, str]) -> None:
        self.md = markdown.Markdown(extensions=["tables", "fenced_code", "sane_lists"])
        self.links = LinkRewriter(self.md, "", note_ids, [])
        self.md.treeprocessors.register(self.links, "trilium", 0)

    def __call__(self, rel: str, body: str) -> tuple[str, list[str]]:
        """Return the note HTML and the relative links/images that can't resolve."""
        self.links.rel, self.links.unresolved = rel, []
        html = self.md.reset().convert(body)
        return html, self.links.unresolved


def parent_dir(rel: str) -> str:
    return posixpath.dirname(rel)


def duplicates_message(
    duplicated: dict[str, list[dict]], claims: dict[str, list[dict]], roots: list
) -> str:
    """Explain which of several notes claiming one path is the script's own.

    Trilium's Duplicate copies labels, so a copy (perhaps edited by hand)
    carries the same path, hash and #readOnly as the note it was made from.
    Deleting the wrong one loses those edits or turns the copy into the
    managed note, so name the likely original and have the labels removed
    from the rest instead. A copy is newer, and Duplicate puts it next to
    the original, so creation date decides and placement under the
    expected parent note only breaks a tie.
    """

    def created(n: dict) -> str:
        return n.get("utcDateCreated") or n.get("dateCreated") or ""

    lines = []
    for path, notes in sorted(duplicated.items()):
        parent = parent_dir(path)
        parent_ids = {
            n["noteId"] for n in (claims.get(parent, []) if parent else roots)
        }
        placed = {
            n["noteId"]: any(p in parent_ids for p in n.get("parentNoteIds") or [])
            for n in notes
        }
        ranked = sorted(
            notes,
            key=lambda n: (
                not created(n),
                created(n),
                not placed[n["noteId"]],
                n["noteId"],
            ),
        )
        lines.append(f"{len(notes)} notes carry {PATH_LABEL}={path}:")
        for i, n in enumerate(ranked):
            where = "under its parent note" if placed[n["noteId"]] else "elsewhere"
            when = f"created {created(n)}" if created(n) else "creation date unknown"
            mark = "  <- likely the original" if i == 0 else ""
            lines.append(
                f"  {n['noteId']} '{n.get('title', '')}', {when}, {where}{mark}"
            )
    lines.append(
        "Trilium's Duplicate copies labels, so a copy looks managed too. Don't "
        f"delete a note: remove the {PATH_LABEL} and {HASH_LABEL} labels (and "
        "readOnly, to keep editing it) from each copy, then rerun."
    )
    return "\n".join(lines)


def sync(
    api: Etapi,
    files: list[str],
    sources: dict[str, tuple[str, str]],
    scope: list[str],
    linkable: set[str],
    prune: bool,
) -> None:
    """Sync `files` (whose (title, body) are in `sources`). `linkable` is every
    syncable path repo-wide, so links to docs outside the scope still resolve.
    Notes outside the scope are never written: a doc linking to a note pruned
    by a scoped run is fixed by the next run that covers that doc, since the
    hash covers the rendered links."""
    roots = api.search(f"#{ROOT_LABEL}")
    roots = [n for n in roots if label(n, ROOT_LABEL)]
    if len(roots) > 1:
        sys.exit(
            f"{len(roots)} notes carry #{ROOT_LABEL}; "
            "keep one and remove the label from the others"
        )
    # The whole tree: a doc note moved elsewhere in Trilium is found and
    # updated in place instead of duplicated.
    existing = api.search(f"#{PATH_LABEL}")
    claims: dict[str, list[dict]] = {}
    for note in existing:
        attr = label(note, PATH_LABEL)
        if attr:  # not matched through an inherited label only
            claims.setdefault(attr["value"], []).append(note)
    duplicated = {p: ns for p, ns in claims.items() if len(ns) > 1}
    if duplicated:
        sys.exit(duplicates_message(duplicated, claims, roots))
    by_path = {p: ns[0] for p, ns in claims.items()}

    # Everything that can be checked before writing is checked here, so a bad
    # run exits before touching Trilium.
    wanted = with_parents(files)
    stale = sorted(p for p in by_path if p not in wanted and in_scope(p, scope))
    # A path that matched no doc and no stale note is most likely a typo, or a
    # gitignored folder: say so rather than report a successful no-op.
    unmatched = [
        s for s in scope if not any(in_scope(p, [s]) for p in [*files, *stale])
    ]
    if unmatched:
        sys.exit(f"Nothing to sync or prune under: {', '.join(unmatched)}")
    # ETAPI can't open a protected session: it shows a protected note's title
    # as "[protected]" and can't write to the note, so such a note is left
    # alone, neither updated nor pruned.
    protected = {
        p for p, n in by_path.items() if n.get("isProtected") and in_scope(p, scope)
    }
    for rel in sorted(protected):
        nid = by_path[rel]["noteId"]
        if rel in wanted:
            print(
                f"! {rel}: note {nid} is protected, so ETAPI can't update it; "
                "skipped (unprotect it in Trilium to sync it)"
            )
        else:
            print(
                f"! {rel} is no longer in the repo, but note {nid} is protected, "
                "so it isn't pruned; delete it in Trilium by hand"
            )
    stale = [p for p in stale if p not in protected]

    if roots:
        root_id = roots[0]["noteId"]
    elif any(label(n, PATH_LABEL) for n in existing):
        sys.exit(
            f"Doc notes exist but no note carries #{ROOT_LABEL}. Add that label "
            f"back to the '{ROOT_TITLE}' note, so its tree isn't split in two."
        )
    else:
        print(f"Creating '{ROOT_TITLE}' under the Trilium root")
        root_id = api.create("root", ROOT_TITLE, {ROOT_LABEL: "", "sorted": ""})

    # Known notes are link targets only while their path is still syncable,
    # in or out of this run's scope: a link to a deleted, ignored or excluded
    # doc is reported, not pointed at a note that --prune may remove.
    note_ids = {p: n["noteId"] for p, n in by_path.items() if p in linkable}
    note_ids[""] = root_id

    # Folder notes first, so each file has a parent. Root-level files go
    # straight under the root note.
    # Sorting puts every folder before its subfolders.
    created = 0
    for sub in sorted(wanted - set(files)):
        name = posixpath.basename(sub)
        folder = by_path.get(sub)
        if folder and in_scope(sub, scope) and sub not in protected:
            # Folder notes follow the repo too: name and #sorted.
            if folder["title"] != name:
                api.call("PATCH", f"/notes/{folder['noteId']}", {"title": name})
            if not label(folder, "sorted"):
                api.add_label(folder["noteId"], "sorted")
        elif not folder and sub not in note_ids:
            print(f"+ folder {sub}/")
            note_ids[sub] = api.create(
                note_ids[parent_dir(sub)], name, {PATH_LABEL: sub, "sorted": ""}
            )
            created += 1

    # Pass 1: make sure every file has a note, so links can point at it.
    for rel in files:
        title = sources[rel][0]
        if rel not in note_ids:
            print(f"+ {rel}")
            created += 1
            note_ids[rel] = api.create(
                note_ids[parent_dir(rel)], title, {PATH_LABEL: rel, "readOnly": ""}
            )

    # Pass 2: write content where the final HTML changed. Hashing the output,
    # not the source, means a doc is rewritten when a link it holds starts
    # resolving or its target note is recreated with a new ID.
    render = Renderer(note_ids)
    updated = 0
    for rel in files:
        if rel in protected:
            continue
        title, body = sources[rel]
        content, unresolved = render(rel, body)
        nid = note_ids[rel]
        note = by_path.get(rel)
        # The repo is the source of truth for the title and #readOnly too,
        # even when the content hasn't changed.
        if note and note["title"] != title:
            print(f"~ {rel} (title)")
            api.call("PATCH", f"/notes/{nid}", {"title": title})
        if note and not label(note, "readOnly"):
            api.add_label(nid, "readOnly")
        digest = hashlib.sha256((title + "\0" + content).encode()).hexdigest()[:16]
        hash_attr = label(note, HASH_LABEL) if note else None
        if hash_attr and hash_attr["value"] == digest:
            continue
        # Reported only for docs actually written, so runs stay quiet.
        for href in unresolved:
            print(f"  note: {rel} links to '{href}', which isn't a synced doc")
        if note:
            print(f"~ {rel}")
        api.call("PUT", f"/notes/{nid}/content", content, raw_text=True)
        # The hash is recorded only after the content is written, so an
        # interrupted run leaves the note marked as needing a rewrite.
        if hash_attr:
            api.call(
                "PATCH", f"/attributes/{hash_attr['attributeId']}", {"value": digest}
            )
        else:
            api.add_label(nid, HASH_LABEL, digest)
        updated += 1

    # Stale: known paths inside this run's scope that no longer exist. A run
    # on `docs/x.md` never touches the rest. Stale notes are deleted deepest
    # path first, so the stale docs under a stale folder go before it.
    # A note is only deleted when nothing but already-deleted stale notes sit
    # under it, so a live doc or hand-made note moved there is never lost.
    # Passes repeat until one deletes nothing, so the order notes really sit
    # in Trilium doesn't matter. A note that also appears elsewhere (a clone)
    # is never deleted: DELETE would remove it from every place it appears.
    pruned_ids: set[str] = set()
    pending = sorted(stale, key=lambda p: (-p.count("/"), p))
    if not prune:
        for rel in pending:
            print(f"! {rel} is no longer in the repo (rerun with --prune to delete it)")
        pending = []
    blocked: dict[str, str] = {}
    subtree: dict[str, list[str]] = {}
    progress = True
    while pending and progress:
        progress, blocked = False, {}
        for rel in pending:
            note = by_path[rel]
            # System parents such as _share aren't clones.
            parents = [
                p for p in note.get("parentNoteIds", []) if not p.startswith("_")
            ]
            if len(parents) > 1:
                blocked[rel] = (
                    "it's cloned elsewhere in Trilium; remove the clones first"
                )
                continue
            if rel not in subtree:
                subtree[rel] = api.descendants(note["noteId"])
            keep = [c for c in subtree[rel] if c not in pruned_ids]
            if keep:
                blocked[rel] = f"it holds {len(keep)} note(s) that aren't stale docs"
                continue
            print(f"- {rel}")
            api.call("DELETE", f"/notes/{note['noteId']}")
            pruned_ids.add(note["noteId"])
            progress = True
        pending = [p for p in pending if p in blocked]
    for rel, why in blocked.items():
        print(f"! {rel}: not pruned, {why}")
    if (created or pruned_ids) and scope != [""]:
        print(
            "  Notes were created or pruned: docs outside this run's paths that "
            "link to them are updated the next time a run covers them."
        )

    skipped = sum(rel in protected for rel in files)
    print(
        f"{len(files)} docs, {updated} written, "
        f"{len(files) - updated - skipped} unchanged, "
        + (f"{skipped} protected (skipped), " if skipped else "")
        + f"{len(stale)} stale, {len(pruned_ids)} pruned"
    )


def read_token() -> str:
    """The ETAPI token, trimmed like the token file is (a value set with
    `$(cat file)` from a CRLF file keeps its CR). A token holding anything
    but printable ASCII is refused by a message that never repeats it."""
    token, source = os.environ.get("TRILIUM_ETAPI_TOKEN", "").strip(), None
    if token:
        source = "TRILIUM_ETAPI_TOKEN"
    elif TOKEN_FILE.is_file():
        token, source = TOKEN_FILE.read_text().strip(), str(TOKEN_FILE)
    if not token:
        sys.exit(f"No ETAPI token: set TRILIUM_ETAPI_TOKEN or write it to {TOKEN_FILE}")
    if not re.fullmatch(r"[\x21-\x7e]+", token):
        sys.exit(
            f"The ETAPI token in {source} contains whitespace, control or "
            "non-ASCII characters; copy it again from Trilium -> Options -> ETAPI"
        )
    return token


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("paths", nargs="*", default=[str(REPO_ROOT / "docs")])
    ap.add_argument("--url", default=os.environ.get("TRILIUM_URL", DEFAULT_URL))
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would change, write nothing (docs linking to a doc that "
        "would be created show as changed too)",
    )
    ap.add_argument(
        "--prune",
        action="store_true",
        help="delete notes whose file is gone from the repo",
    )
    args = ap.parse_args()
    url = urllib.parse.urlsplit(args.url)
    if url.scheme != "https" and url.hostname not in ("localhost", "127.0.0.1", "::1"):
        sys.exit(f"{args.url}: refusing to send the ETAPI token over {url.scheme}")

    token = read_token()
    every = syncable_files()
    files, scope = collect_files(args.paths, every)
    # Read every in-scope file up front, so a bad one stops the run before any write.
    # utf-8-sig drops a BOM, and CRLF is normalised so headings still match.
    sources = {}
    for rel in files:
        try:
            text = (REPO_ROOT / rel).read_text("utf-8-sig").replace("\r\n", "\n")
        except (OSError, UnicodeDecodeError) as err:
            sys.exit(f"{rel}: {err}")
        sources[rel] = split_title(rel, text)
    api = Etapi(args.url, token, args.dry_run)
    try:
        sync(api, files, sources, scope, with_parents(every), args.prune)
    except EtapiError as err:
        sys.exit(f"ETAPI request failed: {err}")


if __name__ == "__main__":
    main()
