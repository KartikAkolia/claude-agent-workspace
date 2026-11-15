#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown>=3.6"]
# ///
"""Mirror this repo's Markdown docs into Trilium as read-only text notes.

Notes are matched by a workspaceDocPath label and rewritten only when their
rendered HTML changes; notes for deleted files are removed only with --prune.
Each path is a file or folder inside the repo (default: docs/). URL: --url or
TRILIUM_URL. Token: TRILIUM_ETAPI_TOKEN or ~/.config/trilium-etapi-token.
"""

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
    cmd = ["bash", str(REPO_ROOT / "list-lint-files.sh"), "--reference-clones"]
    try:
        result = subprocess.run(
            cmd, cwd=REPO_ROOT, capture_output=True, text=True, check=False
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
NOT_RELATIVE = re.compile(r"[a-z][a-z0-9+.-]*:|#|//|\?|\x02", re.IGNORECASE)


class EtapiError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib would replay the Authorization header (the token) to the new host.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise EtapiError(
            f"{req.get_method()} {req.full_url}: redirected to {newurl}", code
        )


OPENER = urllib.request.build_opener(NoRedirect)
ID_CHARS = string.ascii_letters + string.digits


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
        headers = {"Authorization": self.token, "User-Agent": "sync-docs-to-trilium/1"}
        data = None
        if body is not None:
            data = (body if raw_text else json.dumps(body)).encode()
            kind = "text/plain; charset=utf-8" if raw_text else "application/json"
            headers["Content-Type"] = kind
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
        except (OSError, http.client.HTTPException) as err:
            raise EtapiError(f"{method} {path}: {err}") from err
        except ValueError as err:
            raise EtapiError(
                f"{method} {path}: invalid request ({type(err).__name__}, "
                "details withheld as they can quote the token); check the token "
                "and URL"
            ) from None
        if not payload and method in ("GET", "POST"):
            raise EtapiError(f"{method} {path}: empty response")
        try:
            return json.loads(payload) if payload else None
        except json.JSONDecodeError as err:
            raise EtapiError(f"{method} {path}: response isn't JSON: {err}") from err

    def search(self, query: str) -> list[dict]:
        params = {"search": query, "limit": "10000", "includeArchivedNotes": "true"}
        found = self.call("GET", "/notes?" + urllib.parse.urlencode(params))
        if len(found["results"]) >= int(params["limit"]):
            raise EtapiError(f"search {query!r} hit the {params['limit']} result cap")
        return found["results"]

    def create(self, parent: str, title: str, labels: dict[str, str]) -> str:
        note_id = self.create_note(parent, title)
        try:
            for name, value in labels.items():
                self.add_label(note_id, name, value)
        except BaseException:
            self.discard(note_id)
            raise
        return note_id

    def create_note(self, parent: str, title: str) -> str:
        note_id = "".join(secrets.choice(ID_CHARS) for _ in range(12))
        body = {"parentNoteId": parent, "title": title, "type": "text", "content": ""}
        try:
            created = self.call("POST", "/create-note", {**body, "noteId": note_id})
        except EtapiError as err:
            refused = err.status is not None and err.status < 500
            if refused or not self.was_created(note_id, parent, title):
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
            return returned
        if self.was_created(note_id, parent, title):
            return note_id
        raise EtapiError(f"create-note: unexpected response {created!r}")

    def was_created(self, note_id: str, parent: str, title: str) -> bool:
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
    return next(
        (a for a in note["attributes"] if a["type"] == "label" and a["name"] == name),
        None,
    )


def rel_path(p: str) -> str:
    full = Path(os.path.abspath(p))
    if not full.is_relative_to(REPO_ROOT):
        aliased = full.parent.resolve() / full.name
        full = aliased if aliased.is_relative_to(REPO_ROOT) else full
    if not full.is_relative_to(REPO_ROOT) and full.is_dir():
        full = full.resolve()
    if not full.is_relative_to(REPO_ROOT):
        sys.exit(f"{p}: outside the repo")
    rel = full.relative_to(REPO_ROOT).as_posix()
    return "" if rel == "." else rel


def excluded(rel: str) -> bool:
    parts = rel.split("/")
    return parts[0] in reference_clones() or any(
        part.startswith(".") or part == "node_modules" for part in parts
    )


def syncable_files() -> list[str]:
    cmd = ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    try:
        listed = subprocess.run(
            [*cmd, "--", "*.md"], cwd=REPO_ROOT, capture_output=True, check=True
        )
    except (OSError, subprocess.CalledProcessError) as err:
        detail = getattr(err, "stderr", b"") or err
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace").strip()
        sys.exit(f"Can't list repo files with git: {detail}")
    names = listed.stdout.decode("utf-8", "surrogateescape").split("\0")
    candidates = {f for f in names if f and not excluded(f)}
    return sorted(f for f in candidates if publishable(f, candidates))


def in_scope(p: str, scope: list[str]) -> bool:
    return any(s == "" or p == s or p.startswith(s + "/") for s in scope)


def publishable(rel: str, candidates: set[str]) -> bool:
    # A symlink must not publish a file from outside the repo or an excluded path.
    path = REPO_ROOT / rel
    if not path.is_file():
        return False
    real = path.resolve()
    inside = real.is_relative_to(REPO_ROOT)
    return inside and real.relative_to(REPO_ROOT).as_posix() in candidates


def collect_files(paths: list[str], every: list[str]) -> tuple[list[str], list[str]]:
    scope = [rel_path(p) for p in paths]
    files = [f for f in every if in_scope(f, scope)]
    for p, s in zip(paths, scope, strict=True):
        if s and excluded(s):
            sys.exit(f"{p}: excluded from syncing (hidden, node_modules or a clone)")
        if (REPO_ROOT / s).is_file() and s not in files:
            sys.exit(f"{p}: not a syncable Markdown file")
    return files, scope


def with_parents(files: list[str]) -> set[str]:
    out = set(files)
    for f in files:
        while f := posixpath.dirname(f):
            out.add(f)
    return out


TITLE_MD = markdown.Markdown()


def plain_title(md_title: str) -> str:
    escaped = md_title.replace("<", "\ue000")
    escaped = re.sub(r"\A(\d+)([.)])", r"\1\\\2", escaped)
    escaped = re.sub(r"\A([-+*])(?=[ \t])|\A([>#])", r"\\\1\2", escaped)
    html = TITLE_MD.reset().convert(escaped)
    text = htmllib.unescape(re.sub(r"<[^>]+>", "", html))
    return text.replace("\ue000", "<").strip()


def split_title(rel: str, text: str) -> tuple[str, str]:
    fallback = Path(rel).stem
    fm = FRONT_MATTER.match(text)
    yaml = (fm.group(1) or "") if fm else ""
    if fm and all(
        re.match(r"[a-z0-9_-]+:(?:[ \t]|$)|[ \t]|- ", line) or not line.strip()
        for line in yaml.splitlines()
    ):
        text = text[fm.end() :]
        fm_title = re.search(r"^title:[ \t]*(.+?)[ \t]*$", yaml, re.MULTILINE)
        fallback = fm_title.group(1).strip("\"'") if fm_title else fallback
    comments = LEADING_COMMENTS.match(text).group(0)
    rest = text[len(comments) :]
    match = ATX_H1.match(rest) or SETEXT_H1.match(rest)
    title = plain_title(match.group(1)) if match else ""
    if not title:
        return fallback, text
    body = rest[match.end() :]
    return title, (comments + "\n\n" + body) if comments.strip() else body


class Renderer(Treeprocessor):
    def __init__(self, note_ids: dict[str, str]) -> None:
        md = markdown.Markdown(extensions=["tables", "fenced_code", "sane_lists"])
        super().__init__(md)
        self.note_ids = note_ids
        md.treeprocessors.register(self, "trilium", 0)

    def __call__(self, rel: str, body: str) -> tuple[str, list[str]]:
        self.rel, self.unresolved = rel, []
        return self.md.reset().convert(body), self.unresolved

    def run(self, root):
        for el in root.iter():
            attr = {"a": "href", "img": "src"}.get(el.tag)
            raw = el.get(attr) if attr else None
            if not raw or NOT_RELATIVE.match(raw):
                continue
            path = urllib.parse.unquote(re.split(r"[?#]", raw, maxsplit=1)[0])
            base = "" if path.startswith("/") else posixpath.dirname(self.rel)
            target = posixpath.normpath(posixpath.join(base, path.lstrip("/")))
            target = "" if target == "." else target
            note_id = self.note_ids.get(target) if el.tag == "a" else None
            if note_id:
                el.set("href", f"#root/{note_id}")
            else:
                self.unresolved.append(urllib.parse.unquote(raw))


def duplicates_message(
    duplicated: dict[str, list[dict]], claims: dict[str, list[dict]], roots: list
) -> str:
    def created(n: dict) -> str:
        return n.get("utcDateCreated") or n.get("dateCreated") or ""

    def rank(n: dict, placed: dict[str, bool]) -> tuple:
        return (not created(n), created(n), not placed[n["noteId"]], n["noteId"])

    lines = []
    for path, notes in sorted(duplicated.items()):
        parent = posixpath.dirname(path)
        parent_ids = {
            n["noteId"] for n in (claims.get(parent, []) if parent else roots)
        }
        placed = {
            n["noteId"]: any(p in parent_ids for p in n.get("parentNoteIds") or [])
            for n in notes
        }
        lines.append(f"{len(notes)} notes carry {PATH_LABEL}={path}:")
        for i, n in enumerate(sorted(notes, key=lambda n: rank(n, placed))):
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
    roots = [n for n in api.search(f"#{ROOT_LABEL}") if label(n, ROOT_LABEL)]
    if len(roots) > 1:
        sys.exit(
            f"{len(roots)} notes carry #{ROOT_LABEL}; "
            "keep one and remove the label from the others"
        )
    claims: dict[str, list[dict]] = {}
    for note in api.search(f"#{PATH_LABEL}"):
        if attr := label(note, PATH_LABEL):
            claims.setdefault(attr["value"], []).append(note)
    duplicated = {p: ns for p, ns in claims.items() if len(ns) > 1}
    if duplicated:
        sys.exit(duplicates_message(duplicated, claims, roots))
    by_path = {p: ns[0] for p, ns in claims.items()}

    wanted = with_parents(files)
    stale = sorted(p for p in by_path if p not in wanted and in_scope(p, scope))
    unmatched = [
        s for s in scope if not any(in_scope(p, [s]) for p in [*files, *stale])
    ]
    if unmatched:
        sys.exit(f"Nothing to sync or prune under: {', '.join(unmatched)}")
    protected = {
        p for p, n in by_path.items() if n.get("isProtected") and in_scope(p, scope)
    }
    for rel in sorted(protected):
        nid = by_path[rel]["noteId"]
        print(
            f"! {rel}: note {nid} is protected, so ETAPI can't update it; "
            "skipped (unprotect it in Trilium to sync it)"
            if rel in wanted
            else f"! {rel} is no longer in the repo, but note {nid} is protected, "
            "so it isn't pruned; delete it in Trilium by hand"
        )
    stale = [p for p in stale if p not in protected]

    if roots:
        root_id = roots[0]["noteId"]
    elif claims:
        sys.exit(
            f"Doc notes exist but no note carries #{ROOT_LABEL}. Add that label "
            f"back to the '{ROOT_TITLE}' note, so its tree isn't split in two."
        )
    else:
        print(f"Creating '{ROOT_TITLE}' under the Trilium root")
        root_id = api.create("root", ROOT_TITLE, {ROOT_LABEL: "", "sorted": ""})

    note_ids = {p: n["noteId"] for p, n in by_path.items() if p in linkable}
    note_ids[""] = root_id

    created = 0
    for sub in sorted(wanted - set(files)):
        name = posixpath.basename(sub)
        folder = by_path.get(sub)
        managed = folder and in_scope(sub, scope) and sub not in protected
        if managed and folder["title"] != name:
            api.call("PATCH", f"/notes/{folder['noteId']}", {"title": name})
        if managed and not label(folder, "sorted"):
            api.add_label(folder["noteId"], "sorted")
        if not folder and sub not in note_ids:
            print(f"+ folder {sub}/")
            parent = note_ids[posixpath.dirname(sub)]
            note_ids[sub] = api.create(parent, name, {PATH_LABEL: sub, "sorted": ""})
            created += 1

    for rel in [f for f in files if f not in note_ids]:
        print(f"+ {rel}")
        created += 1
        parent, title = note_ids[posixpath.dirname(rel)], sources[rel][0]
        note_ids[rel] = api.create(parent, title, {PATH_LABEL: rel, "readOnly": ""})

    render = Renderer(note_ids)
    updated = 0
    for rel in [f for f in files if f not in protected]:
        title, body = sources[rel]
        content, unresolved = render(rel, body)
        nid = note_ids[rel]
        note = by_path.get(rel)
        if note and note["title"] != title:
            print(f"~ {rel} (title)")
            api.call("PATCH", f"/notes/{nid}", {"title": title})
        if note and not label(note, "readOnly"):
            api.add_label(nid, "readOnly")
        digest = hashlib.sha256((title + "\0" + content).encode()).hexdigest()[:16]
        hash_attr = label(note, HASH_LABEL) if note else None
        if hash_attr and hash_attr["value"] == digest:
            continue
        for href in unresolved:
            print(f"  note: {rel} links to '{href}', which isn't a synced doc")
        if note:
            print(f"~ {rel}")
        api.call("PUT", f"/notes/{nid}/content", content, raw_text=True)
        # The hash goes last, so an interrupted write is retried on the next run.
        if hash_attr:
            api.call(
                "PATCH", f"/attributes/{hash_attr['attributeId']}", {"value": digest}
            )
        else:
            api.add_label(nid, HASH_LABEL, digest)
        updated += 1

    pruned_ids: set[str] = set()
    pending = sorted(stale, key=lambda p: (-p.count("/"), p))
    if not prune:
        for rel in pending:
            print(f"! {rel} is no longer in the repo (rerun with --prune to delete it)")
        pending = []
    # Never prune a clone (DELETE removes every placement) or a note holding others.
    descendants = functools.cache(api.descendants)
    blocked: dict[str, str] = {}
    progress = False
    while pending:
        rel = pending.pop(0)
        note = by_path[rel]
        parents = [p for p in note.get("parentNoteIds", []) if not p.startswith("_")]
        held = [] if len(parents) > 1 else descendants(note["noteId"])
        keep = [c for c in held if c not in pruned_ids]
        if len(parents) > 1:
            blocked[rel] = "it's cloned elsewhere in Trilium; remove the clones first"
        elif keep:
            blocked[rel] = f"it holds {len(keep)} note(s) that aren't stale docs"
        else:
            print(f"- {rel}")
            api.call("DELETE", f"/notes/{note['noteId']}")
            pruned_ids.add(note["noteId"])
            progress = True
        if not pending and progress:
            pending, blocked, progress = list(blocked), {}, False
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
    source = "TRILIUM_ETAPI_TOKEN"
    token = os.environ.get(source, "").strip()
    if not token and TOKEN_FILE.is_file():
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
    ap.add_argument("--dry-run", action="store_true", help="show what would change")
    ap.add_argument("--prune", action="store_true", help="delete stale notes")
    args = ap.parse_args()
    url = urllib.parse.urlsplit(args.url)
    if url.scheme != "https" and url.hostname not in ("localhost", "127.0.0.1", "::1"):
        sys.exit(f"{args.url}: refusing to send the ETAPI token over {url.scheme}")

    token = read_token()
    every = syncable_files()
    files, scope = collect_files(args.paths, every)
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
