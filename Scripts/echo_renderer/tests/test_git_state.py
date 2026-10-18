from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from echo_renderer.git_state import ApprovedWorktree


GIT = "/usr/bin/git"


class ApprovedWorktreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name) / "renderer-source").resolve()
        self.root.mkdir()
        self._git("init", "--quiet")
        self._git("config", "user.name", "Renderer Tests")
        self._git("config", "user.email", "renderer-tests@example.invalid")
        (self.root / "source.txt").write_text("approved\n", encoding="utf-8")
        self._git("add", "source.txt")
        self._git("commit", "--quiet", "-m", "approved source")
        self.approved_sha = self._git("rev-parse", "HEAD").strip()

    def _git(self, *arguments: str) -> str:
        completed = subprocess.run(
            [GIT, *arguments],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout

    def test_attests_a_clean_canonical_worktree_at_the_exact_head(self):
        attested = ApprovedWorktree.attest(self.root, self.approved_sha)

        self.assertEqual(
            attested,
            ApprovedWorktree(root=self.root, approved_sha=self.approved_sha),
        )
        attested.reattest()

    def test_rejects_noncanonical_and_symbolic_link_roots(self):
        nested = self.root / "nested"
        nested.mkdir()
        noncanonical = nested / ".."
        link = self.root.parent / "renderer-source-link"
        link.symlink_to(self.root, target_is_directory=True)

        for root in (noncanonical, link):
            with self.subTest(root=root):
                with self.assertRaises(ValueError):
                    ApprovedWorktree.attest(root, self.approved_sha)

    def test_rejects_a_canonical_directory_below_the_worktree_root(self):
        nested = self.root / "nested"
        nested.mkdir()

        with self.assertRaises(ValueError):
            ApprovedWorktree.attest(nested, self.approved_sha)

    def test_rejects_invalid_approved_shas(self):
        invalid_shas = (
            "a" * 39,
            "a" * 41,
            "A" * 40,
            "g" * 40,
            f"{self.approved_sha}\n",
        )

        for approved_sha in invalid_shas:
            with self.subTest(approved_sha=approved_sha):
                with self.assertRaises(ValueError):
                    ApprovedWorktree.attest(self.root, approved_sha)

    def test_rejects_a_different_head(self):
        with self.assertRaises(ValueError):
            ApprovedWorktree.attest(self.root, "0" * 40)

    def test_rejects_tracked_and_untracked_changes(self):
        (self.root / "source.txt").write_text("modified\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ApprovedWorktree.attest(self.root, self.approved_sha)

        self._git("restore", "source.txt")
        (self.root / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ApprovedWorktree.attest(self.root, self.approved_sha)

    def test_reattest_rejects_changes_after_initial_attestation(self):
        attested = ApprovedWorktree.attest(self.root, self.approved_sha)
        (self.root / "source.txt").write_text("modified later\n", encoding="utf-8")

        with self.assertRaises(ValueError):
            attested.reattest()

    def test_reattest_rejects_a_new_head_after_initial_attestation(self):
        attested = ApprovedWorktree.attest(self.root, self.approved_sha)
        (self.root / "source.txt").write_text("new revision\n", encoding="utf-8")
        self._git("add", "source.txt")
        self._git("commit", "--quiet", "-m", "new revision")

        with self.assertRaises(ValueError):
            attested.reattest()
