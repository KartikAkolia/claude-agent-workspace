#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown>=3.6"]
# ///
"""Offline regression tests for the Trilium documentation sync."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("sync-docs-to-trilium.py")
spec = importlib.util.spec_from_file_location("trilium_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def note(note_id, name, value="", **extra):
    return {
        "noteId": note_id,
        "attributes": [{"type": "label", "name": name, "value": value}],
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
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "target.md").write_text("root", encoding="utf-8")
            with patch.object(sync, "REPO_ROOT", root):
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
        sync.sync(api, [], {}, ["docs"], set(), True)
        self.assertEqual(api.writes, [])


if __name__ == "__main__":
    unittest.main()
