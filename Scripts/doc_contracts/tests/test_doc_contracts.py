# SPDX-License-Identifier: GPL-3.0-or-later
"""Contracts over the real working tree, plus the scope-detection unit tests."""

from __future__ import annotations

import unittest
from pathlib import Path

from doc_contracts import changed_scope, contracts


class DocContractTests(unittest.TestCase):
    """The ported SettingsHelpPathTests / TimelineLanguageCleanupTests checks."""

    def test_documentation_and_help_text_match_the_shipping_ui(self) -> None:
        violations = contracts.check()
        self.assertEqual(
            violations,
            [],
            "documentation contracts failed:\n  "
            + "\n  ".join(str(v) for v in violations),
        )

    def test_every_contracted_file_exists(self) -> None:
        for contract in contracts.all_contracts():
            with self.subTest(path=contract.path):
                self.assertTrue(
                    (contracts.REPO_ROOT / contract.path).is_file(),
                    f"{contract.path} is under contract but missing; update "
                    f"Scripts/doc_contracts/contracts.py if it moved",
                )

    def test_contracts_cover_both_manuals_and_architecture(self) -> None:
        """Guard against a contract being silently dropped during an edit."""
        covered = {contract.path for contract in contracts.all_contracts()}
        for required in (
            "ARCHITECTURE.md",
            "docs/guides/user-manual.md",
            "docs/manual.html",
            "EchoCore/Views/HelpContent.swift",
        ):
            self.assertIn(required, covered)

    def test_a_forbidden_string_is_actually_detected(self) -> None:
        """The checker must fail on a planted violation, not just pass quietly."""
        root = Path(self.enterContext(_temp_repo()))
        (root / "docs" / "guides").mkdir(parents=True)
        (root / "docs" / "guides" / "user-manual.md").write_text(
            "Settings → Player Controls\n", encoding="utf-8"
        )
        violations = contracts.check(root)
        kinds = {v.kind for v in violations}
        self.assertIn("forbidden", kinds)
        self.assertIn("missing", kinds)


class DocOnlyScopeTests(unittest.TestCase):
    def test_markdown_and_docs_paths_are_doc_only(self) -> None:
        self.assertTrue(changed_scope.is_doc_only(["ARCHITECTURE.md"]))
        self.assertTrue(changed_scope.is_doc_only(["docs/guides/user-manual.md"]))
        self.assertTrue(changed_scope.is_doc_only(["docs/manual.html"]))
        self.assertTrue(
            changed_scope.is_doc_only(["README.md", "docs/focus.html", "CHANGELOG.md"])
        )

    def test_any_non_doc_path_forces_the_full_gate(self) -> None:
        self.assertFalse(
            changed_scope.is_doc_only(["ARCHITECTURE.md", "EchoCore/Models/Book.swift"])
        )
        self.assertFalse(changed_scope.is_doc_only(["Echo.xcodeproj/project.pbxproj"]))
        self.assertFalse(changed_scope.is_doc_only([".github/workflows/ci.yml"]))
        self.assertFalse(changed_scope.is_doc_only(["EchoCore/Localizable.xcstrings"]))

    def test_bundled_markdown_is_not_doc_only(self) -> None:
        """THIRD_PARTY_NOTICES.md ships inside the app, so it is a build input."""
        self.assertFalse(changed_scope.is_doc_only(["THIRD_PARTY_NOTICES.md"]))
        self.assertFalse(
            changed_scope.is_doc_only(["ARCHITECTURE.md", "THIRD_PARTY_NOTICES.md"])
        )

    def test_empty_change_set_is_not_doc_only(self) -> None:
        """If CI cannot tell what changed, it must run the full gate."""
        self.assertFalse(changed_scope.is_doc_only([]))
        self.assertFalse(changed_scope.is_doc_only(["", "   "]))

    def test_project_markdown_is_declared(self) -> None:
        """Tripwire: bundling new Markdown must not silently skip the gate."""
        changed_scope.assert_build_input_docs_declared(
            changed_scope.PBXPROJ.read_text(encoding="utf-8")
        )

    def test_tripwire_fires_on_undeclared_markdown(self) -> None:
        with self.assertRaises(AssertionError) as caught:
            changed_scope.assert_build_input_docs_declared(
                'path = BUNDLED_GUIDE.md; sourceTree = SOURCE_ROOT;'
            )
        self.assertIn("BUNDLED_GUIDE.md", str(caught.exception))


def _temp_repo():
    import tempfile

    return tempfile.TemporaryDirectory()


if __name__ == "__main__":
    unittest.main()
