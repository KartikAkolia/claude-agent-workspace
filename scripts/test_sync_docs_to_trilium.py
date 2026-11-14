#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown==3.11.3"]
# ///
"""Offline regression tests for the Trilium documentation sync.

Run: uv run --script scripts/test_sync_docs_to_trilium.py -v -- as
lint-python.yml does. markdown is pinned above (the one place), to the
version these pass with, so CI and a local run test the same thing; bump it
there by hand, like the linters in .lint-versions.
"""

import contextlib
import http.client
import importlib.util
import io
import os
import subprocess
import tempfile
import traceback
import unittest
import urllib.parse
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("sync-docs-to-trilium.py")
spec = importlib.util.spec_from_file_location("trilium_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

P = sync.PATH_LABEL


def note(note_id, name, value="", **extra):
    return {
        "noteId": note_id,
        "attributes": [{"type": "label", "name": name, "value": value}],
        **extra,
    }


def tree_note(note_id, parents, labels=None, title="t", **extra):
    return {
        "noteId": note_id,
        "title": title,
        "parentNoteIds": list(parents),
        "childNoteIds": [],
        "attributes": [
            {"type": "label", "name": k, "value": v, "attributeId": f"{note_id}-{k}"}
            for k, v in (labels or {}).items()
        ],
        **extra,
    }


class FakeApi:
    def __init__(self, roots=(), notes=(), descendants=()):
        self.roots, self.notes = roots, notes
        self.children = descendants
        self.writes = []

    def search(self, query):
        return self.roots if query == f"#{sync.ROOT_LABEL}" else self.notes

    def create(self, *args):
        self.writes.append(("create", args))
        return "new"

    def call(self, *args, **kwargs):
        self.writes.append((args, kwargs))

    def descendants(self, note_id):
        return self.children


class TreeApi(sync.Etapi):
    """An in-memory Trilium behind the real Etapi: only call() is replaced, so
    search, create, labelling and descendants run as written."""

    def __init__(self, notes, create_fails=None):
        super().__init__("https://trilium.invalid", "token", False)
        self.notes = {n["noteId"]: n for n in notes}
        for n in notes:
            for p in n["parentNoteIds"]:
                if p in self.notes:
                    self.notes[p]["childNoteIds"].append(n["noteId"])
        # None, or (whether the note is made anyway, the error to raise).
        self.create_fails = create_fails
        self.requests = []

    def deleted(self):
        return [path.rsplit("/", 1)[1] for m, path, _ in self.requests if m == "DELETE"]

    def writes_to(self, note_id):
        return [
            r
            for r in self.requests
            if r[0] != "GET"
            and (
                note_id in r[1] or (isinstance(r[2], dict) and note_id in r[2].values())
            )
        ]

    def call(self, method, path, body=None, raw_text=False):
        self.requests.append((method, path, body))
        if method == "GET" and path.startswith("/notes?"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
            name = query["search"][0].lstrip("#")
            found = [
                n
                for n in self.notes.values()
                if any(a["name"] == name for a in n["attributes"])
            ]
            return {"results": found}
        if method == "GET":
            note_id = path.rsplit("/", 1)[1]
            if note_id not in self.notes:
                raise sync.EtapiError(f"GET {path}: HTTP 404: NOTE_NOT_FOUND", 404)
            return self.notes[note_id]
        if method == "DELETE":
            gone = self.notes.pop(path.rsplit("/", 1)[1])
            for p in gone["parentNoteIds"]:
                if p in self.notes:
                    self.notes[p]["childNoteIds"].remove(gone["noteId"])
            return None
        if path == "/create-note":
            made, error = self.create_fails or (True, None)
            new = tree_note(body["noteId"], [body["parentNoteId"]], title=body["title"])
            if made:
                self.notes[new["noteId"]] = new
                self.notes[body["parentNoteId"]]["childNoteIds"].append(new["noteId"])
            if error:
                raise error
            return {"note": new, "branch": {}}
        if path == "/attributes":
            attrs = self.notes[body["noteId"]]["attributes"]
            attrs.append({k: body[k] for k in ("type", "name", "value")})
            return attrs[-1]
        return {}


def docs_tree(*extra):
    """The root note, the docs folder note and a live doc, docs/a.md."""
    return [
        tree_note("R", ["root"], {sync.ROOT_LABEL: ""}),
        tree_note("D", ["R"], {P: "docs", "sorted": ""}, "docs"),
        tree_note("A", ["D"], {P: "docs/a.md", "readOnly": ""}, "A"),
        *extra,
    ]


def run_sync(api, files, scope=("docs",), prune=True):
    """Run sync() on docs whose title is "A", returning what it printed."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        sync.sync(
            api,
            list(files),
            dict.fromkeys(files, ("A", "body")),
            list(scope),
            sync.with_parents(list(files)),
            prune,
        )
    return out.getvalue()


class SyncTests(unittest.TestCase):
    def test_relative_and_explicit_root_links(self):
        renderer = sync.Renderer({"docs/target.md": "local", "target.md": "root"})
        html, unresolved = renderer(
            "docs/source.md", "[local](target.md) [root](/target.md)"
        )
        self.assertIn('href="#root/local"', html)
        self.assertIn('href="#root/root"', html)
        self.assertEqual(unresolved, [])

    def test_deleted_relative_target_does_not_fall_back_to_root(self):
        # docs/target.md is gone (no note ID); target.md at the repo root
        # still has one, and a relative link must not land on it.
        renderer = sync.Renderer({"target.md": "root"})
        html, unresolved = renderer("docs/source.md", "[link](target.md)")
        self.assertNotIn('href="#root/root"', html)
        self.assertEqual(unresolved, ["target.md"])

    def test_doc_symlink_through_checkout_alias_keeps_its_name(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"
            root.mkdir()
            (root / "target.md").write_text("target", encoding="utf-8")
            (root / "link.md").symlink_to("target.md")
            alias = Path(temp) / "alias"
            alias.symlink_to(root, target_is_directory=True)
            with (
                patch.object(sync, "REPO_ROOT", root),
                patch.object(sync, "reference_clones", return_value=frozenset()),
            ):
                self.assertEqual(sync.rel_path(str(alias / "link.md")), "link.md")
                self.assertEqual(sync.rel_path(str(alias)), "")
                self.assertEqual(
                    sync.collect_files(
                        [str(alias / "link.md")], ["link.md", "target.md"]
                    ),
                    (["link.md"], ["link.md"]),
                )

    def test_unmatched_scope_stops_before_writes(self):
        api = FakeApi()
        with self.assertRaisesRegex(SystemExit, "Nothing to sync or prune"):
            sync.sync(
                api,
                ["docs/a.md"],
                {"docs/a.md": ("A", "body")},
                ["docs", "typo"],
                {"docs", "docs/a.md"},
                True,
            )
        self.assertEqual(api.writes, [])

    def test_prune_preserves_unmanaged_descendants(self):
        root = note("root-id", sync.ROOT_LABEL)
        stale = note("stale-id", sync.PATH_LABEL, "docs/old", parentNoteIds=["root-id"])
        api = FakeApi([root], [stale], ["manual-id"])
        with contextlib.redirect_stdout(io.StringIO()):
            sync.sync(api, [], {}, ["docs"], set(), True)
        self.assertEqual(api.writes, [])


class PruneTests(unittest.TestCase):
    def test_prune_off_deletes_nothing(self):
        api = TreeApi(docs_tree(tree_note("OLD", ["D"], {P: "docs/old.md"})))
        out = run_sync(api, ["docs/a.md"], prune=False)
        self.assertEqual(api.deleted(), [])
        self.assertIn("docs/old.md is no longer in the repo (rerun with --prune", out)

    def test_note_cloned_outside_the_tree_is_not_pruned(self):
        api = TreeApi(
            docs_tree(
                tree_note("MINE", ["root"]),
                tree_note("C", ["D", "MINE"], {P: "docs/cloned.md"}),
                # A system parent such as _share isn't a clone.
                tree_note("SH", ["D", "_share"], {P: "docs/shared.md"}),
            )
        )
        out = run_sync(api, ["docs/a.md"])
        self.assertEqual(api.deleted(), ["SH"])
        self.assertIn("docs/cloned.md: not pruned, it's cloned elsewhere", out)

    def test_stale_note_outside_the_scope_is_not_pruned(self):
        api = TreeApi(
            [
                tree_note("R", ["root"], {sync.ROOT_LABEL: ""}),
                tree_note("D", ["R"], {P: "docs", "sorted": ""}, "docs"),
                tree_note("S", ["D"], {P: "docs/sub", "sorted": ""}, "sub"),
                tree_note("A", ["S"], {P: "docs/sub/a.md", "readOnly": ""}, "A"),
                tree_note("OLD", ["S"], {P: "docs/sub/old.md"}),
                tree_note("OTHER", ["D"], {P: "docs/other.md"}),
            ]
        )
        out = run_sync(api, ["docs/sub/a.md"], scope=["docs/sub"])
        self.assertEqual(api.deleted(), ["OLD"])
        self.assertNotIn("docs/other.md", out)
        self.assertEqual(api.writes_to("OTHER"), [])

    def test_nested_stale_folder_and_docs_are_deleted_child_first(self):
        api = TreeApi(
            docs_tree(
                tree_note("F", ["D"], {P: "docs/old"}),
                tree_note("F1", ["F"], {P: "docs/old/a.md"}),
                tree_note("F2", ["F"], {P: "docs/old/deep"}),
                tree_note("F3", ["F2"], {P: "docs/old/deep/b.md"}),
            )
        )
        out = run_sync(api, ["docs/a.md"])
        self.assertEqual(api.deleted(), ["F3", "F1", "F2", "F"])
        self.assertNotIn("not pruned", out)
        self.assertIn("4 stale, 4 pruned", out)


class DuplicateTests(unittest.TestCase):
    def test_duplicate_path_names_the_original_and_keeps_both_notes(self):
        stamp = "2026-0{}-01 10:00:00.000Z"
        labels = {P: "docs/b.md", sync.HASH_LABEL: "h", "readOnly": ""}
        api = TreeApi(
            docs_tree(
                # Listed first, under the same parent, as Duplicate leaves it.
                tree_note(
                    "COPY", ["D"], labels, "B (dup)", utcDateCreated=stamp.format(3)
                ),
                tree_note("ORIG", ["D"], labels, "B", utcDateCreated=stamp.format(1)),
            )
        )
        with self.assertRaises(SystemExit) as caught:
            run_sync(api, ["docs/a.md", "docs/b.md"])
        message = str(caught.exception.code)
        self.assertRegex(message, r"ORIG 'B', created 2026-01-01.*likely the original")
        self.assertNotRegex(message, r"COPY .*likely the original")
        self.assertIn(f"remove the {P} and {sync.HASH_LABEL} labels", message)
        self.assertIn("Don't delete a note", message)
        self.assertEqual([r for r in api.requests if r[0] != "GET"], [])


class ProtectedTests(unittest.TestCase):
    def test_protected_notes_are_neither_written_nor_pruned(self):
        hidden = {"title": "[protected]", "isProtected": True}
        notes = docs_tree(
            tree_note("PF", ["D"], {P: "docs/sub", "sorted": ""}, **hidden),
            tree_note(
                "PD", ["PF"], {P: "docs/sub/p.md", sync.HASH_LABEL: "x"}, **hidden
            ),
            tree_note("PS", ["D"], {P: "docs/gone.md"}, **hidden),
        )
        api = TreeApi(notes)
        out = run_sync(api, ["docs/a.md", "docs/sub/p.md"])
        for note_id in ("PF", "PD", "PS"):
            self.assertEqual(api.writes_to(note_id), [], note_id)
        self.assertNotIn("/create-note", [r[1] for r in api.requests])
        self.assertIn("docs/sub/p.md: note PD is protected", out)
        self.assertIn("docs/gone.md is no longer in the repo, but note PS", out)
        self.assertIn("1 protected (skipped), 0 stale, 0 pruned", out)


class CreateTests(unittest.TestCase):
    def test_lost_create_response_adopts_the_note(self):
        api = TreeApi(docs_tree(), (True, sync.EtapiError("POST: timed out")))
        with contextlib.redirect_stderr(io.StringIO()) as err:
            note_id = api.create("D", "New", {P: "docs/new.md"})
        sent = [r[2] for r in api.requests if r[1] == "/create-note"]
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["noteId"], note_id)
        self.assertEqual(api.notes["D"]["childNoteIds"].count(note_id), 1)
        self.assertEqual(sync.label(api.notes[note_id], P)["value"], "docs/new.md")
        self.assertEqual(api.deleted(), [])
        self.assertIn("using it", err.getvalue())

    def test_failed_create_that_made_nothing_raises(self):
        error = sync.EtapiError("POST /create-note: HTTP 502: bad gateway", 502)
        api = TreeApi(docs_tree(), (False, error))
        with self.assertRaises(sync.EtapiError) as caught:
            api.create("D", "New", {P: "docs/new.md"})
        self.assertIs(caught.exception, error)
        self.assertEqual([r[0] for r in api.requests], ["POST", "GET"])
        self.assertEqual(set(api.notes), {"R", "D", "A"})

    def test_interrupted_create_is_cleaned_up(self):
        api = TreeApi(docs_tree(), (True, KeyboardInterrupt()))
        with self.assertRaises(KeyboardInterrupt):
            api.create("D", "New", {P: "docs/new.md"})
        sent = [r[2]["noteId"] for r in api.requests if r[1] == "/create-note"]
        self.assertEqual(api.deleted(), sent)
        self.assertEqual(set(api.notes), {"R", "D", "A"})

    def test_refused_create_is_not_looked_up(self):
        error = sync.EtapiError("POST /create-note: HTTP 409: exists", 409)
        api = TreeApi(docs_tree(), (False, error))
        with self.assertRaises(sync.EtapiError):
            api.create("D", "New", {P: "docs/new.md"})
        self.assertEqual([r[0] for r in api.requests], ["POST"])

    def test_note_with_the_id_but_not_ours_is_left_alone(self):
        def collide(method, path, body=None, raw_text=False):
            if path == "/create-note":
                api.notes[body["noteId"]] = tree_note(body["noteId"], ["X"], title="?")
                raise sync.EtapiError("POST: reset by peer")
            return TreeApi.call(api, method, path, body, raw_text)

        api = TreeApi(docs_tree())
        with patch.object(api, "call", collide), self.assertRaises(sync.EtapiError):
            api.create("D", "New", {P: "docs/new.md"})
        self.assertEqual(api.deleted(), [])
        self.assertEqual(len(api.notes), 4)  # the other note is still there


SECRET = "SECRET-token-abc123"


class TokenTests(unittest.TestCase):
    def test_header_error_never_shows_the_token(self):
        api = sync.Etapi("http://127.0.0.1:9", SECRET + "\r", False)
        # http.client checks headers before connecting; fail loudly if not.
        no_network = AssertionError("tried to connect")
        with (
            patch.object(http.client.HTTPConnection, "connect", side_effect=no_network),
            self.assertRaises(sync.EtapiError) as caught,
        ):
            api.call("GET", "/notes/x")
        shown = "".join(traceback.format_exception(caught.exception))
        self.assertNotIn(SECRET, shown)
        self.assertNotIn(SECRET, repr(caught.exception))
        self.assertIn("details withheld", shown)

    def test_crlf_env_token_is_trimmed_and_never_printed(self):
        sent = []

        def fake_sync(api, *args):
            sent.append(api.token)
            api.call("GET", "/notes/x")  # the connection is refused below

        refused = ConnectionRefusedError("refused")
        env = {"TRILIUM_ETAPI_TOKEN": SECRET + "\r\n"}
        stderr = io.StringIO()
        with (
            patch.dict(os.environ, env),
            patch.object(sync.sys, "argv", ["sync", "--url", "http://127.0.0.1:9"]),
            patch.object(sync, "syncable_files", return_value=[]),
            patch.object(sync, "collect_files", return_value=([], [""])),
            patch.object(sync, "sync", fake_sync),
            patch.object(http.client.HTTPConnection, "connect", side_effect=refused),
            contextlib.redirect_stderr(stderr),
            self.assertRaises(SystemExit) as caught,
        ):
            sync.main()
        self.assertEqual(sent, [SECRET])
        self.assertIn("ETAPI request failed", str(caught.exception.code))
        self.assertNotIn(SECRET, str(caught.exception.code) + stderr.getvalue())

    def test_token_with_inner_control_character_is_refused_unshown(self):
        for bad in (SECRET[:6] + "\r" + SECRET[6:], SECRET + " x", SECRET + "\u2019"):
            with (
                patch.dict(os.environ, {"TRILIUM_ETAPI_TOKEN": bad}),
                self.assertRaises(SystemExit) as caught,
            ):
                sync.read_token()
            message = str(caught.exception.code)
            self.assertIn("TRILIUM_ETAPI_TOKEN contains whitespace", message)
            self.assertNotIn(SECRET[6:], message)


class ReferenceClonesTests(unittest.TestCase):
    """reference-clones.tsv is the one list of mirrors, and list-lint-files.sh
    the one parser of it; this script reads that parser's output (a stale
    copy of the rules once made every sync exit before writing anything)."""

    MIRRORS = frozenset(
        {
            "dwm-titus-main",
            "linutil-main",
            "titus-ai-main",
            "website-master",
            "winutil-main",
        }
    )

    def setUp(self):
        sync.reference_clones.cache_clear()
        self.addCleanup(sync.reference_clones.cache_clear)

    def lister_copy(self, text):
        # A copy of the real list-lint-files.sh beside its own
        # reference-clones.tsv, as REPO_ROOT for this script to read.
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        lister = (sync.REPO_ROOT / "list-lint-files.sh").read_text(encoding="utf-8")
        (root / "list-lint-files.sh").write_text(lister, encoding="utf-8")
        if text is not None:
            (root / "reference-clones.tsv").write_bytes(text.encode())
        return root

    def test_real_file_names_the_five_mirrors(self):
        # Unstubbed: what an actual run of this script excludes, through
        # the real list-lint-files.sh on the real reference-clones.tsv.
        self.assertEqual(sync.reference_clones(), self.MIRRORS)
        table = sync.reference_clone_table()
        self.assertEqual({c for c, _, _ in table}, self.MIRRORS)
        self.assertTrue(all(r.startswith("ChrisTitusTech/") for _, r, _ in table))

    def test_refresh_lookup_maps_each_repo_to_its_mirror(self):
        # llf_reference_clone_for is how refresh-reference-clone.sh picks the
        # one directory it may rsync into; GitHub names are case-insensitive.
        script = (
            'source "$1" || exit 1; shift; for repo in "$@"; do '
            'llf_reference_clone_for "$repo" || exit 1; '
            'printf "%s %s\\n" "$LLF_CLONE_DIR" "$LLF_CLONE_BRANCH"; done'
        )
        table = sync.reference_clone_table()
        repos = [repo.upper() for _, repo, _ in table]
        result = subprocess.run(
            [
                "bash",
                "-c",
                script,
                "_",
                str(sync.REPO_ROOT / "list-lint-files.sh"),
                *repos,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"{c} {b}" for c, _, b in table])

    def test_a_valid_copy_is_read_through_the_lister(self):
        root = self.lister_copy(
            "@owners ChrisTitusTech\r\nlinutil-main\tchrisTITUStech/linutil  main # c\r\n"
        )
        with patch.object(sync, "REPO_ROOT", root):
            self.assertEqual(
                sync.reference_clone_table(),
                [("linutil-main", "chrisTITUStech/linutil", "main")],
            )

    def test_a_bad_list_stops_the_run_with_the_listers_error(self):
        cases = {
            "linutil-main ChrisTitusTech/linutil main\n": 'no "@owners',
            "@owners ChrisTitusTech\nclaude-agent-templates someone/claude-agent templates\n": (
                "someone is not a reference-clone owner"
            ),
            "@owners ChrisTitusTech\ndocs ChrisTitusTech/linutil main\n": (
                "docs should be named linutil-main"
            ),
            "@owners ChrisTitusTech\nlinutil-main ChrisTitusTech/linutil\n": "want",
            "@owners ChrisTitusTech\n": "lists no reference clones",
            None: "missing or unreadable",
        }
        for text, message in cases.items():
            with self.subTest(text=text):
                sync.reference_clones.cache_clear()
                root = self.lister_copy(text)
                with (
                    patch.object(sync, "REPO_ROOT", root),
                    self.assertRaises(SystemExit) as stop,
                ):
                    sync.reference_clones()
                self.assertIn(
                    "Can't read the reference-clone list", str(stop.exception)
                )
                self.assertIn(message, str(stop.exception))

    def test_no_bash_stops_the_run(self):
        with (
            patch.object(sync.subprocess, "run", side_effect=FileNotFoundError("bash")),
            self.assertRaises(SystemExit) as stop,
        ):
            sync.reference_clones()
        self.assertIn("can't run bash", str(stop.exception))


if __name__ == "__main__":
    unittest.main()
