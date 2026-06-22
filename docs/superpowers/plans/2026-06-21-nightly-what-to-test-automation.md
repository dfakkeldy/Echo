# Nightly "What to Test" Automation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every nightly TestFlight build, auto-draft `fastlane/testflight/what_to_test.txt` from the commit delta since the last weekly promotion, deterministically, so internal testers always see fresh "What to Test" copy — while weekly/external builds keep using the human-curated committed file.

**Architecture:** A small dependency-free Python package `Scripts/doc_automation/` with two pure modules (commit parsing/categorization, and TestFlight rendering) and one thin I/O CLI. The Fastfile `beta` lane, guarded by `channel == "nightly"`, regenerates the file in the working tree (never committed) right before fastlane reads it. The pure "change extractor" (`changes.py`) is the reusable spine that later phases (release notes, PR docs-gate) will consume.

**Tech Stack:** Python 3 (standard library only — no pip deps), `unittest` (stdlib) for tests, Conventional Commits, `git log` via `subprocess`, Ruby (fastlane) for the one-line lane hook, Make for the local affordance.

## Global Constraints

Every task's requirements implicitly include these (copied from the spec):

- **Deterministic only — NO LLM anywhere in the generation path.** The nightly file ships unreviewed; a hallucinated/overclaimed bullet is the honesty-ledger failure mode being avoided.
- **No edit to `.github/workflows/release-trains.yml` or any `main`-targeting change.** Everything lands via the normal `→ nightly` PR route.
- **TestFlight "What to Test" hard cap: 4000 characters.**
- **Filter:** include Conventional-Commit types `feat`, `fix`, `perf`; exclude `chore`/`ci`/`docs`/`refactor`/`test`/`build`/`style` and any non-conventional subject. Trailer `Tester-note: <text>` forces a verbatim bullet; trailer `skip-changelog` hides a commit.
- **Change window:** `merge-base(origin/weekly, HEAD)..HEAD` — stateless (no CI tags/bookkeeping).
- **Materialization:** nightly regenerates the file in the working tree only (**never committed**); the weekly channel does not regenerate and uses the committed curated file.
- **Fail-safe:** on an empty delta OR any error, leave the existing committed `what_to_test.txt` untouched and exit 0 — never fail the build.
- **Placement:** all Python lives under `Scripts/doc_automation/`. `Tools/` stays reserved for the transcription pipeline (per CLAUDE.md).
- **Bullet text rule (refines the spec's illustrative example):** a generated bullet is the Conventional-Commit *description* only — scope dropped — with the first letter capitalized and any trailing period removed. (`feat(reader): pinch-to-zoom` → `Pinch-to-zoom`.) Scope-bearing context that matters to testers is supplied via a `Tester-note:` trailer.
- **Invocation convention (used identically by tests, Make, and the Fastfile):** run from the repo root as `PYTHONPATH=Scripts python3 -m doc_automation.whats_new ...`; file path args are repo-root-relative.

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/doc_automation/__init__.py` | Empty package marker. |
| `Scripts/doc_automation/changes.py` | **Pure spine.** Parse Conventional-Commit subjects + trailers → `CategorizedChanges`. |
| `Scripts/doc_automation/render_testflight.py` | **Pure.** `CategorizedChanges` + template → final string; enforces the 4000-char cap with graceful truncation. |
| `Scripts/doc_automation/whats_new.py` | **I/O shell.** `git log` plumbing, wires the pure modules, fail-safe, writes the output file (or stdout). |
| `Scripts/doc_automation/tests/__init__.py` | Empty test-package marker. |
| `Scripts/doc_automation/tests/test_changes.py` | Unit tests for `changes.py`. |
| `Scripts/doc_automation/tests/test_render_testflight.py` | Unit tests for `render_testflight.py`. |
| `Scripts/doc_automation/tests/test_whats_new.py` | Integration test (temp git repo) for `whats_new.py`. |
| `fastlane/testflight/what_to_test.template.txt` | Human-owned frame with a `{{CHANGES}}` placeholder. |
| `fastlane/Fastfile` | Modify the `beta` lane: add the nightly-guarded regeneration step. |
| `Makefile` | Add `whats-new` (dry-run) and `doc-automation-test` targets. |
| `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md` | Doc-sync at the end. |

---

### Task 1: `changes.py` — commit parsing & categorization (the pure spine)

**Files:**
- Create: `Scripts/doc_automation/__init__.py`
- Create: `Scripts/doc_automation/changes.py`
- Create: `Scripts/doc_automation/tests/__init__.py`
- Test: `Scripts/doc_automation/tests/test_changes.py`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `RawCommit(subject: str, body: str = "")` — frozen dataclass.
  - `CategorizedChanges(new: list[str], fixed: list[str], improved: list[str])` with `.is_empty() -> bool` and `.total() -> int`.
  - `clean_description(desc: str) -> str`
  - `find_trailers(body: str) -> tuple[str | None, bool]` → `(tester_note, skip)`
  - `categorize(commits: list[RawCommit]) -> CategorizedChanges`

- [ ] **Step 1: Create the package markers**

Create `Scripts/doc_automation/__init__.py` (empty) and `Scripts/doc_automation/tests/__init__.py` (empty).

- [ ] **Step 2: Write the failing tests**

Create `Scripts/doc_automation/tests/test_changes.py`:

```python
import unittest

from doc_automation.changes import (
    RawCommit,
    CategorizedChanges,
    clean_description,
    find_trailers,
    categorize,
)


class CleanDescriptionTests(unittest.TestCase):
    def test_capitalizes_and_strips_trailing_period(self):
        self.assertEqual(clean_description("pinch-to-zoom."), "Pinch-to-zoom")

    def test_leaves_already_capitalized(self):
        self.assertEqual(clean_description("Pinch-to-zoom"), "Pinch-to-zoom")

    def test_empty_stays_empty(self):
        self.assertEqual(clean_description("   "), "")


class FindTrailersTests(unittest.TestCase):
    def test_tester_note_extracted(self):
        note, skip = find_trailers("body text\nTester-note: Re-import your library to test")
        self.assertEqual(note, "Re-import your library to test")
        self.assertFalse(skip)

    def test_skip_changelog_bare(self):
        note, skip = find_trailers("body\nskip-changelog")
        self.assertIsNone(note)
        self.assertTrue(skip)

    def test_skip_changelog_explicit_false(self):
        _, skip = find_trailers("body\nSkip-Changelog: false")
        self.assertFalse(skip)

    def test_no_trailers(self):
        self.assertEqual(find_trailers("just a body"), (None, False))


class CategorizeTests(unittest.TestCase):
    def test_includes_feat_fix_perf_and_groups_them(self):
        result = categorize([
            RawCommit("feat(reader): pinch-to-zoom"),
            RawCommit("fix(player): correct seek drift"),
            RawCommit("perf(db): faster library load"),
        ])
        self.assertEqual(result.new, ["Pinch-to-zoom"])
        self.assertEqual(result.fixed, ["Correct seek drift"])
        self.assertEqual(result.improved, ["Faster library load"])

    def test_excludes_non_user_facing_types(self):
        result = categorize([
            RawCommit("chore: bump deps"),
            RawCommit("ci: tweak workflow"),
            RawCommit("docs: update readme"),
            RawCommit("refactor: rename service"),
            RawCommit("test: add coverage"),
            RawCommit("build: adjust settings"),
            RawCommit("style: format"),
        ])
        self.assertTrue(result.is_empty())

    def test_non_conventional_subject_excluded(self):
        self.assertTrue(categorize([RawCommit("random commit message")]).is_empty())

    def test_skip_changelog_drops_included_type(self):
        result = categorize([RawCommit("feat: secret thing", "body\nskip-changelog")])
        self.assertTrue(result.is_empty())

    def test_tester_note_forces_bullet_with_its_text(self):
        result = categorize([
            RawCommit("chore: internal", "body\nTester-note: Please test offline playback"),
        ])
        self.assertEqual(result.new, ["Please test offline playback"])

    def test_tester_note_grouped_by_type_when_recognized(self):
        result = categorize([
            RawCommit("fix(sync): edge case", "Tester-note: Verify sync after airplane mode"),
        ])
        self.assertEqual(result.fixed, ["Verify sync after airplane mode"])
        self.assertEqual(result.new, [])

    def test_total_and_is_empty(self):
        empty = CategorizedChanges()
        self.assertTrue(empty.is_empty())
        self.assertEqual(empty.total(), 0)
        self.assertEqual(categorize([RawCommit("feat: a"), RawCommit("fix: b")]).total(), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_changes -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'doc_automation.changes'`.

- [ ] **Step 4: Write the implementation**

Create `Scripts/doc_automation/changes.py`:

```python
"""Pure commit parsing & categorization — the reusable change-extractor spine.

No I/O, no git, no LLM. Given Conventional-Commit subjects/bodies, produce a
grouped, filtered, tester-facing change list.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# type(scope)!: description  — scope and the breaking-change "!" are optional.
CONVENTIONAL_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<desc>.+)$"
)

# Conventional-Commit type -> CategorizedChanges attribute name.
INCLUDED_TYPES = {"feat": "new", "fix": "fixed", "perf": "improved"}


@dataclass(frozen=True)
class RawCommit:
    subject: str
    body: str = ""


@dataclass
class CategorizedChanges:
    new: list[str] = field(default_factory=list)       # feat
    fixed: list[str] = field(default_factory=list)      # fix
    improved: list[str] = field(default_factory=list)   # perf

    def is_empty(self) -> bool:
        return not (self.new or self.fixed or self.improved)

    def total(self) -> int:
        return len(self.new) + len(self.fixed) + len(self.improved)


def clean_description(desc: str) -> str:
    desc = desc.strip().rstrip(".").strip()
    if not desc:
        return ""
    return desc[:1].upper() + desc[1:]


def find_trailers(body: str) -> tuple[str | None, bool]:
    """Parse commit-body trailers. Returns (tester_note, skip)."""
    tester_note: str | None = None
    skip = False
    for line in body.splitlines():
        stripped = line.strip()
        lower = stripped.lower()
        if lower.startswith("tester-note:"):
            tester_note = stripped.split(":", 1)[1].strip()
        elif lower == "skip-changelog" or lower.startswith("skip-changelog:"):
            value = stripped.split(":", 1)[1].strip().lower() if ":" in stripped else "true"
            skip = value not in ("false", "no", "0")
    return tester_note, skip


def categorize(commits: list[RawCommit]) -> CategorizedChanges:
    result = CategorizedChanges()
    for commit in commits:
        tester_note, skip = find_trailers(commit.body)
        if skip:
            continue
        match = CONVENTIONAL_RE.match(commit.subject.strip())
        ctype = match.group("type") if match else None
        if tester_note is not None:
            bullet = tester_note
            group = INCLUDED_TYPES.get(ctype, "new")
        else:
            if ctype not in INCLUDED_TYPES:
                continue
            group = INCLUDED_TYPES[ctype]
            bullet = clean_description(match.group("desc"))
        if bullet:
            getattr(result, group).append(bullet)
    return result
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_changes -v`
Expected: PASS (all tests OK).

- [ ] **Step 6: Commit**

```bash
git add Scripts/doc_automation/__init__.py Scripts/doc_automation/changes.py \
        Scripts/doc_automation/tests/__init__.py Scripts/doc_automation/tests/test_changes.py
git commit -m "feat(doc-automation): commit change-extractor (changes.py)"
```

---

### Task 2: `render_testflight.py` — rendering, grouping, char cap

**Files:**
- Create: `Scripts/doc_automation/render_testflight.py`
- Test: `Scripts/doc_automation/tests/test_render_testflight.py`

**Interfaces:**
- Consumes: `CategorizedChanges` from `doc_automation.changes`.
- Produces:
  - `PLACEHOLDER = "{{CHANGES}}"`
  - `DEFAULT_MAX_CHARS = 4000`
  - `EMPTY_MESSAGE = "No user-facing changes since the last weekly build."`
  - `render(changes: CategorizedChanges, template: str, max_chars: int = DEFAULT_MAX_CHARS) -> str`

- [ ] **Step 1: Write the failing tests**

Create `Scripts/doc_automation/tests/test_render_testflight.py`:

```python
import unittest

from doc_automation.changes import CategorizedChanges
from doc_automation.render_testflight import (
    render,
    PLACEHOLDER,
    DEFAULT_MAX_CHARS,
    EMPTY_MESSAGE,
)

TEMPLATE = f"Intro line.\n\n{PLACEHOLDER}\n\nOutro line."


class RenderTests(unittest.TestCase):
    def test_fills_placeholder_with_grouped_bullets(self):
        changes = CategorizedChanges(new=["Pinch-to-zoom"], fixed=["Seek drift"], improved=["Faster load"])
        out = render(changes, TEMPLATE)
        self.assertIn("Intro line.", out)
        self.assertIn("Outro line.", out)
        self.assertIn("New", out)
        self.assertIn("• Pinch-to-zoom", out)
        self.assertIn("Fixed", out)
        self.assertIn("• Seek drift", out)
        self.assertIn("Improved", out)
        self.assertIn("• Faster load", out)
        self.assertNotIn(PLACEHOLDER, out)

    def test_omits_empty_groups(self):
        out = render(CategorizedChanges(new=["Only a feature"]), TEMPLATE)
        self.assertIn("New", out)
        self.assertNotIn("Fixed", out)
        self.assertNotIn("Improved", out)

    def test_empty_changes_uses_empty_message(self):
        out = render(CategorizedChanges(), TEMPLATE)
        self.assertIn(EMPTY_MESSAGE, out)

    def test_respects_char_cap_with_truncation_summary(self):
        many = CategorizedChanges(new=[f"Feature number {i} with some descriptive text" for i in range(200)])
        out = render(many, TEMPLATE, max_chars=500)
        self.assertLessEqual(len(out), 500)
        self.assertIn("more change", out)

    def test_under_cap_has_no_truncation_summary(self):
        out = render(CategorizedChanges(new=["Small"]), TEMPLATE, max_chars=DEFAULT_MAX_CHARS)
        self.assertNotIn("more change", out)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_render_testflight -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'doc_automation.render_testflight'`.

- [ ] **Step 3: Write the implementation**

Create `Scripts/doc_automation/render_testflight.py`:

```python
"""Pure rendering of CategorizedChanges into a TestFlight 'What to Test' string."""
from __future__ import annotations

from doc_automation.changes import CategorizedChanges

PLACEHOLDER = "{{CHANGES}}"
DEFAULT_MAX_CHARS = 4000
EMPTY_MESSAGE = "No user-facing changes since the last weekly build."
BULLET = "•"  # •

# (attribute name, display heading) in display order.
GROUPS = [("new", "New"), ("fixed", "Fixed"), ("improved", "Improved")]


def _format_block(changes: CategorizedChanges) -> str:
    if changes.is_empty():
        return EMPTY_MESSAGE
    blocks: list[str] = []
    for attr, heading in GROUPS:
        bullets = getattr(changes, attr)
        if bullets:
            lines = [heading] + [f"{BULLET} {b}" for b in bullets]
            blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _flatten(changes: CategorizedChanges) -> list[tuple[str, str]]:
    return [(attr, b) for attr, _ in GROUPS for b in getattr(changes, attr)]


def _subset(flat: list[tuple[str, str]], keep: int) -> CategorizedChanges:
    subset = CategorizedChanges()
    for attr, bullet in flat[:keep]:
        getattr(subset, attr).append(bullet)
    return subset


def render(changes: CategorizedChanges, template: str, max_chars: int = DEFAULT_MAX_CHARS) -> str:
    out = template.replace(PLACEHOLDER, _format_block(changes))
    if len(out) <= max_chars:
        return out

    flat = _flatten(changes)
    for keep in range(len(flat) - 1, -1, -1):
        block = _format_block(_subset(flat, keep))
        dropped = len(flat) - keep
        if dropped:
            suffix = "change" if dropped == 1 else "changes"
            block += f"\n\n…and {dropped} more {suffix}."
        out = template.replace(PLACEHOLDER, block)
        if len(out) <= max_chars:
            return out

    # Frame alone exceeds the cap: hard-truncate.
    return template.replace(PLACEHOLDER, "")[:max_chars]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_render_testflight -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Scripts/doc_automation/render_testflight.py \
        Scripts/doc_automation/tests/test_render_testflight.py
git commit -m "feat(doc-automation): TestFlight renderer with 4000-char cap"
```

---

### Task 3: `whats_new.py` — git plumbing, CLI, fail-safe

**Files:**
- Create: `Scripts/doc_automation/whats_new.py`
- Test: `Scripts/doc_automation/tests/test_whats_new.py`

**Interfaces:**
- Consumes: `RawCommit`, `categorize` from `doc_automation.changes`; `render`, `DEFAULT_MAX_CHARS` from `doc_automation.render_testflight`.
- Produces:
  - `get_commits(base: str, head: str) -> list[RawCommit]`
  - `default_base(head: str = "HEAD") -> str` (= `git merge-base origin/weekly <head>`)
  - `generate(base: str, head: str, template_text: str, max_chars: int = DEFAULT_MAX_CHARS) -> str` (raises `ValueError` on empty delta)
  - `main(argv: list[str] | None = None) -> int` (always returns 0 on the error path; leaves output file untouched)

- [ ] **Step 1: Write the failing integration test**

Create `Scripts/doc_automation/tests/test_whats_new.py`:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_whats_new -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'doc_automation.whats_new'`.

- [ ] **Step 3: Write the implementation**

Create `Scripts/doc_automation/whats_new.py`:

```python
"""CLI: draft the nightly TestFlight 'What to Test' from the commit delta.

Fail-safe by design: on an empty delta or ANY error, the existing output file
is left untouched and the process exits 0 — a nightly build must never break or
ship machine garbage.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from doc_automation.changes import RawCommit, categorize
from doc_automation.render_testflight import render, DEFAULT_MAX_CHARS

UNIT_SEP = "\x1f"    # between subject and body
RECORD_SEP = "\x1e"  # between commits


def _git(args: list[str]) -> str:
    result = subprocess.run(["git", *args], check=True, capture_output=True, text=True)
    return result.stdout


def default_base(head: str = "HEAD") -> str:
    return _git(["merge-base", "origin/weekly", head]).strip()


def get_commits(base: str, head: str) -> list[RawCommit]:
    fmt = f"%s{UNIT_SEP}%b{RECORD_SEP}"
    out = _git(["log", "--no-merges", f"--format={fmt}", f"{base}..{head}"])
    commits: list[RawCommit] = []
    for record in out.split(RECORD_SEP):
        record = record.strip("\n")
        if not record.strip():
            continue
        subject, _, body = record.partition(UNIT_SEP)
        commits.append(RawCommit(subject=subject.strip(), body=body))
    return commits


def generate(base: str, head: str, template_text: str, max_chars: int = DEFAULT_MAX_CHARS) -> str:
    changes = categorize(get_commits(base, head))
    if changes.is_empty():
        raise ValueError("no user-facing changes in range")
    return render(changes, template_text, max_chars)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Draft the nightly TestFlight 'What to Test'.")
    parser.add_argument("--base", help="Base ref (default: merge-base origin/weekly HEAD)")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--template", required=True, help="Path to the frame template (contains {{CHANGES}})")
    parser.add_argument("--out", default="-", help="Output path, or '-' for stdout")
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    args = parser.parse_args(argv)

    try:
        base = args.base or default_base(args.head)
        template_text = Path(args.template).read_text()
        result = generate(base, args.head, template_text, args.max_chars)
    except Exception as error:  # fail-safe: never break the build
        print(f"whats_new: leaving existing file untouched ({error})", file=sys.stderr)
        return 0

    if args.out == "-":
        sys.stdout.write(result)
    else:
        Path(args.out).write_text(result)
        print(f"whats_new: wrote {args.out} ({len(result)} chars)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `PYTHONPATH=Scripts python3 -m unittest doc_automation.tests.test_whats_new -v`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `PYTHONPATH=Scripts python3 -m unittest discover -s Scripts/doc_automation/tests -t Scripts -v`
Expected: PASS (all three test modules).

- [ ] **Step 6: Commit**

```bash
git add Scripts/doc_automation/whats_new.py Scripts/doc_automation/tests/test_whats_new.py
git commit -m "feat(doc-automation): whats_new CLI with fail-safe file write"
```

---

### Task 4: Template file + Make targets + end-to-end smoke

**Files:**
- Create: `fastlane/testflight/what_to_test.template.txt`
- Modify: `Makefile` (add two targets near the existing `architecture:` target)

**Interfaces:**
- Consumes: `doc_automation.whats_new` (`main`) via the documented invocation.
- Produces: `make whats-new` (dry-run to stdout) and `make doc-automation-test`.

- [ ] **Step 1: Create the human-owned template frame**

Create `fastlane/testflight/what_to_test.template.txt`:

```
Thanks for testing tonight's Echo nightly build.

Here's what's new since the last weekly build:

{{CHANGES}}

Spot something off? Use in-app feedback or reply in TestFlight — thank you!
```

- [ ] **Step 2: Add the Make targets**

In `Makefile`, add these two targets (match the existing `## ` help-comment style used by `architecture:`):

```makefile
whats-new: ## Draft nightly "What to Test" from commits since last weekly (stdout)
	@PYTHONPATH=Scripts python3 -m doc_automation.whats_new \
		--template fastlane/testflight/what_to_test.template.txt --out -

doc-automation-test: ## Run the doc-automation Python unit tests
	@PYTHONPATH=Scripts python3 -m unittest discover -s Scripts/doc_automation/tests -t Scripts -v
```

- [ ] **Step 3: Verify the test target runs the whole suite**

Run: `make doc-automation-test`
Expected: PASS (all tests from Tasks 1–3, OK).

- [ ] **Step 4: Smoke-test the dry-run against the real repo**

Run: `make whats-new`
Expected: EITHER a rendered "What to Test" (intro + grouped bullets) printed to stdout — if there are `feat`/`fix`/`perf` commits since `merge-base(origin/weekly, HEAD)` — OR a stderr line `whats_new: leaving existing file untouched (...)` and no stdout, if the delta is empty or `origin/weekly` is unfetched. Both are correct, non-failing outcomes. (If `origin/weekly` is missing locally, run `git fetch --no-tags origin weekly` first.)

- [ ] **Step 5: Commit**

```bash
git add fastlane/testflight/what_to_test.template.txt Makefile
git commit -m "feat(doc-automation): what_to_test template + make targets"
```

---

### Task 5: Fastfile `beta`-lane hook (nightly-guarded regeneration)

**Files:**
- Modify: `fastlane/Fastfile` (the `beta` lane, between the channel-routing block ≈`:83` and the `File.read("testflight/what_to_test.txt")` at ≈`:143`)

**Interfaces:**
- Consumes: `doc_automation.whats_new` via the documented invocation; the `channel` local already computed at `fastlane/Fastfile:77`.
- Produces: no new symbols — a side effect (regenerated working-tree file) on the nightly channel only.

- [ ] **Step 1: Read the lane to locate the exact insertion point**

Run: `grep -n 'channel\|what_to_test\|File.read' fastlane/Fastfile`
Confirm: `channel` is set (~`:77`), a `UI.message("Release channel: ...")` line follows (~`:83`), and `changelog: File.read("testflight/what_to_test.txt")` is at (~`:143`). Insert the new block immediately **after** the `UI.message("Release channel: ...")` line.

- [ ] **Step 2: Insert the guarded regeneration block**

Add to `fastlane/Fastfile` immediately after the `UI.message("Release channel: ...")` line:

```ruby
    # ── Nightly only: auto-draft "What to Test" from the commit delta ──────
    # Internal/nightly testers should always see fresh copy. Weekly/external
    # builds intentionally skip this and ship the human-curated committed file.
    # Fail-safe: the generator leaves the committed file untouched on empty
    # delta or any error, so this can never break a build.
    if channel == "nightly"
      UI.message("Nightly channel → regenerating testflight/what_to_test.txt from commit delta")
      sh(
        "cd .. && git fetch --no-tags --quiet origin weekly || true && " \
        "PYTHONPATH=Scripts python3 -m doc_automation.whats_new " \
        "--template fastlane/testflight/what_to_test.template.txt " \
        "--out fastlane/testflight/what_to_test.txt"
      )
    end
```

- [ ] **Step 3: Syntax-check the Fastfile**

Run: `ruby -c fastlane/Fastfile`
Expected: `Syntax OK`.

- [ ] **Step 4: Simulate exactly what the lane runs (from the repo root)**

Run:
```bash
git fetch --no-tags --quiet origin weekly || true
PYTHONPATH=Scripts python3 -m doc_automation.whats_new \
  --template fastlane/testflight/what_to_test.template.txt \
  --out fastlane/testflight/what_to_test.txt
git status --short fastlane/testflight/what_to_test.txt
```
Expected: the command exits 0. Either `what_to_test.txt` shows as modified (if there were `feat`/`fix`/`perf` commits since the last weekly) or unchanged (empty delta). **Then restore the committed file so this generated copy is not accidentally committed:**
```bash
git checkout -- fastlane/testflight/what_to_test.txt
```

- [ ] **Step 5: Commit (Fastfile change only)**

```bash
git add fastlane/Fastfile
git commit -m "feat(doc-automation): regenerate what_to_test.txt on nightly builds"
```

---

### Task 6: Documentation sync

**Files:**
- Modify: `ARCHITECTURE.md` (Release Engineering / Promotion Ladder section)
- Modify: `README.md` (only if it has a release/CI section — see step)
- Modify: `CHANGELOG.md` (current/unreleased section)

**Interfaces:** none (documentation).

- [ ] **Step 1: Update ARCHITECTURE.md**

Find the Release Engineering / Promotion Ladder section (search: `grep -n "Promotion Ladder\|Release Engineering" ARCHITECTURE.md`). Add this paragraph at the end of that section:

```markdown
**Nightly "What to Test" auto-draft.** On the `nightly` channel only, the
fastlane `beta` lane regenerates `fastlane/testflight/what_to_test.txt` in the
working tree (never committed) from the commit delta since the last weekly
promotion (`merge-base(origin/weekly, HEAD)..HEAD`). It is a deterministic
transform of Conventional-Commit subjects — `feat`/`fix`/`perf`, plus
`Tester-note:`/`skip-changelog` trailer overrides — with no LLM, capped at
TestFlight's 4000-char limit; on an empty delta or any error it leaves the
committed file untouched. The weekly/external channel skips regeneration and
ships the human-curated committed file. The generator lives in
`Scripts/doc_automation/` (`make whats-new` for a local dry-run) and its pure
`changes.py` is the shared change-extractor for later doc-automation phases.
```

- [ ] **Step 2: Update README.md if applicable**

Run: `grep -ni "release\|testflight\|fastlane\|nightly" README.md | head`
If there is a release/CI/contributing section, add one line:

```markdown
- Nightly TestFlight "What to Test" copy is auto-drafted from commit history (`make whats-new`); see ARCHITECTURE.md ▸ Release Engineering.
```

If README has no such section, skip this step (do not invent a new section).

- [ ] **Step 3: Update CHANGELOG.md**

Run: `grep -n "Unreleased\|## \[" CHANGELOG.md | head` to find the current/top entry. Under it, following the existing bullet style, add:

```markdown
- Nightly TestFlight builds now auto-draft "What to Test" from the commit delta since the last weekly (deterministic, honesty-ledger-safe); weekly/external builds keep the curated copy.
```

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md CHANGELOG.md README.md
git commit -m "docs: document nightly What-to-Test auto-draft"
```

---

## Self-Review

**1. Spec coverage**

| Spec requirement | Task |
|---|---|
| Deterministic transform, no LLM | Tasks 1–3 (pure modules, no LLM dep); Global Constraints |
| Filter `feat`/`fix`/`perf` + trailers | Task 1 (`categorize`, tests) |
| `Tester-note:` forces bullet, `skip-changelog` hides | Task 1 (`find_trailers`, tests) |
| Bullet cleaning (strip prefix, capitalize, drop period) | Task 1 (`clean_description`, tests) |
| Human-owned frame + `{{CHANGES}}` | Task 2 (`render`), Task 4 (template file) |
| 4000-char cap with truncation | Task 2 (`render`, test) |
| Change window `merge-base(origin/weekly, HEAD)..HEAD` | Task 3 (`default_base`) |
| Fail-safe: leave file / exit 0 on empty or error | Task 3 (`main`, tests), Task 5 (lane comment) |
| Ephemeral nightly, curated weekly | Task 5 (`channel == "nightly"` guard) |
| Hook in Fastfile not release-trains.yml; no main edit | Task 5; Global Constraints |
| Local affordance `make whats-new` | Task 4 |
| Lands via `→ nightly` route | All tasks (no `main`/workflow files touched) |
| Doc-sync (ARCHITECTURE/README/CHANGELOG) | Task 6 |
| Placement under `Scripts/doc_automation/`, Tools/ untouched | Tasks 1–4 |

No gaps found.

**2. Placeholder scan:** No "TBD"/"TODO"/"handle edge cases"/"similar to" placeholders; every code and test step contains full content.

**3. Type consistency:** `RawCommit(subject, body)`, `CategorizedChanges(new/fixed/improved)` with `.is_empty()`/`.total()`, `categorize()`, `clean_description()`, `find_trailers()`, `render(changes, template, max_chars)`, `PLACEHOLDER`/`DEFAULT_MAX_CHARS`/`EMPTY_MESSAGE`, `get_commits(base, head)`, `default_base(head)`, `generate(base, head, template_text, max_chars)`, `main(argv)` — names and signatures are used identically across Tasks 1→3 and the Make/Fastfile invocations.
