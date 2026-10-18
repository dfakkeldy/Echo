import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from doc_automation import whats_new


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _commit(cwd, subject, body=""):
    args = ["commit", "--allow-empty", "-m", subject]
    if body:
        args += ["-m", body]
    _git(cwd, *args)


class WhatsNewIntegrationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = self._tmp.name
        _git(self.repo, "init", "-q")
        _git(self.repo, "config", "user.email", "t@example.com")
        _git(self.repo, "config", "user.name", "Test")
        _commit(self.repo, "chore: root commit")
        self.base = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.repo, check=True, capture_output=True, text=True
        ).stdout.strip()
        self._cwd = os.getcwd()
        os.chdir(self.repo)

    def tearDown(self):
        os.chdir(self._cwd)
        self._tmp.cleanup()

    def test_get_commits_excludes_merges_and_parses_body(self):
        _commit(self.repo, "feat: a new thing", "Tester-note: please check")
        commits = whats_new.get_commits(self.base, "HEAD")
        self.assertEqual(len(commits), 1)
        self.assertEqual(commits[0].subject, "feat: a new thing")
        self.assertIn("Tester-note: please check", commits[0].body)

    def test_generate_renders_when_changes_present(self):
        _commit(self.repo, "feat(reader): pinch-to-zoom")
        _commit(self.repo, "fix: seek drift")
        out = whats_new.generate(self.base, "HEAD", "Frame\n\n{{CHANGES}}\n")
        self.assertIn("• Pinch-to-zoom", out)
        self.assertIn("• Seek drift", out)

    def test_generate_raises_on_empty_delta(self):
        _commit(self.repo, "chore: nothing user-facing")
        with self.assertRaises(ValueError):
            whats_new.generate(self.base, "HEAD", "Frame {{CHANGES}}")

    def test_main_leaves_file_untouched_on_empty_delta(self):
        _commit(self.repo, "docs: only docs")
        out_path = Path(self.repo) / "out.txt"
        out_path.write_text("ORIGINAL CURATED COPY")
        tmpl = Path(self.repo) / "tmpl.txt"
        tmpl.write_text("Frame {{CHANGES}}")
        rc = whats_new.main(["--base", self.base, "--head", "HEAD",
                             "--template", str(tmpl), "--out", str(out_path)])
        self.assertEqual(rc, 0)
        self.assertEqual(out_path.read_text(), "ORIGINAL CURATED COPY")

    def test_main_writes_file_when_changes_present(self):
        _commit(self.repo, "feat: shiny feature")
        out_path = Path(self.repo) / "out.txt"
        out_path.write_text("ORIGINAL")
        tmpl = Path(self.repo) / "tmpl.txt"
        tmpl.write_text("Frame\n\n{{CHANGES}}\n")
        rc = whats_new.main(["--base", self.base, "--head", "HEAD",
                             "--template", str(tmpl), "--out", str(out_path)])
        self.assertEqual(rc, 0)
        self.assertIn("• Shiny feature", out_path.read_text())


if __name__ == "__main__":
    unittest.main()
