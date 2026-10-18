# SPDX-License-Identifier: GPL-3.0-or-later
"""Decide whether a change set is documentation-only.

CI uses this to skip the Xcode build gate for pull requests that touch nothing
the compiler or the test suite can observe. The failure mode is one-sided and
silent: a wrong "yes" skips the entire build gate and the PR still reports
green. So the rule is deliberately narrow, defaults to "no", and is unit
tested rather than living as shell in the workflow YAML.

Documentation-only means every changed path is either under docs/ or is a
Markdown file — minus the Markdown files the Xcode project actually consumes.
THIRD_PARTY_NOTICES.md is bundled as an app resource, so editing it is a build
input, not a doc edit. `assert_build_input_docs_declared` is the tripwire that
fails if another Markdown file is added to the project without being listed
here.

Usage (CI):
    python3 -m doc_contracts.changed_scope --stdin < changed_files.txt
prints "true" or "false" and exits 0; exits non-zero if the tripwire trips.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PBXPROJ = REPO_ROOT / "Echo.xcodeproj" / "project.pbxproj"

#: Markdown the build consumes. Editing these must run the full gate.
BUILD_INPUT_DOCS: frozenset[str] = frozenset({"THIRD_PARTY_NOTICES.md"})

#: Path prefixes whose contents are documentation.
DOC_PREFIXES: tuple[str, ...] = ("docs/",)

#: Suffixes that are documentation wherever they appear.
DOC_SUFFIXES: tuple[str, ...] = (".md",)

_MARKDOWN_IN_PBXPROJ = re.compile(r"[A-Za-z0-9_./-]+\.md")


def is_doc_path(path: str) -> bool:
    """True when this single path cannot affect a build or a Swift test."""
    normalized = path.strip().lstrip("./")
    if not normalized:
        return False
    if normalized in BUILD_INPUT_DOCS or Path(normalized).name in BUILD_INPUT_DOCS:
        return False
    if normalized.startswith(DOC_PREFIXES):
        return True
    return normalized.endswith(DOC_SUFFIXES)


def is_doc_only(paths) -> bool:
    """True when every changed path is documentation and there is at least one.

    An empty change set is not documentation-only: if CI could not work out
    what changed, it must run the full gate.
    """
    materialized = [p for p in (path.strip() for path in paths) if p]
    if not materialized:
        return False
    return all(is_doc_path(path) for path in materialized)


def project_referenced_markdown(pbxproj_text: str) -> set[str]:
    """Every Markdown file name the Xcode project mentions."""
    return {Path(match).name for match in _MARKDOWN_IN_PBXPROJ.findall(pbxproj_text)}


def assert_build_input_docs_declared(pbxproj_text: str) -> None:
    """Fail if the project consumes Markdown this module does not know about.

    Without this, bundling a new Markdown resource would quietly make edits to
    it look documentation-only, and CI would skip the build that proves it
    still ships.
    """
    undeclared = project_referenced_markdown(pbxproj_text) - set(BUILD_INPUT_DOCS)
    if undeclared:
        listed = ", ".join(sorted(undeclared))
        raise AssertionError(
            f"Markdown referenced by Echo.xcodeproj but not declared as a build "
            f"input: {listed}. Add it to BUILD_INPUT_DOCS in "
            f"Scripts/doc_contracts/changed_scope.py so documentation-only "
            f"detection keeps running the build gate for it."
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="read newline-separated changed paths from stdin",
    )
    parser.add_argument("paths", nargs="*", help="changed paths")
    args = parser.parse_args(argv)

    if PBXPROJ.is_file():
        assert_build_input_docs_declared(PBXPROJ.read_text(encoding="utf-8"))

    paths = list(args.paths)
    if args.stdin:
        paths.extend(sys.stdin.read().splitlines())

    print("true" if is_doc_only(paths) else "false")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
