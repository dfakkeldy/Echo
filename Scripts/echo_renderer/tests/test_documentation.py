"""Contract tests for the versioned Echo renderer installer documentation.

These tests assert that ``docs/guides/versioned-echo-renderer.md`` documents
each required operating topic and that ``ARCHITECTURE.md`` links to it. Every
assertion anchors on a stable, distinctive identifier -- a file name, an env
var / flag / Make-target name, a JSON field name, or a verbatim phrase lifted
from the store's own error/doc strings -- rather than on exact prose, so
legitimate copyediting of the guide's wording does not break these tests.
Paths are resolved relative to this test file, not the working directory.
"""

from __future__ import annotations

import unittest
from pathlib import Path


# Scripts/echo_renderer/tests/test_documentation.py -> repo root is 3 up.
_REPO_ROOT = Path(__file__).resolve().parents[3]
_GUIDE_PATH = _REPO_ROOT / "docs" / "guides" / "versioned-echo-renderer.md"
_ARCHITECTURE_PATH = _REPO_ROOT / "ARCHITECTURE.md"


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise AssertionError(f"expected {path} to exist and be readable") from error


class VersionedRendererGuideTests(unittest.TestCase):
    """The guide must exist and document every required operating topic."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.guide_text = _read(_GUIDE_PATH)

    def _assert_all_present(self, anchors: tuple[str, ...]) -> None:
        for anchor in anchors:
            self.assertIn(
                anchor,
                self.guide_text,
                f"guide is missing expected anchor: {anchor!r}",
            )

    def test_guide_file_exists(self) -> None:
        self.assertTrue(_GUIDE_PATH.is_file(), f"expected {_GUIDE_PATH} to exist")

    def test_documents_nested_source_manifest_layout(self) -> None:
        self._assert_all_present(
            (
                "Application Support/Echo/Renderers",
                "40-hex source SHA",
                "64-hex manifest SHA",
                "echo-cli",
                "EchoNarrationResources",
                "renderer-manifest.json",
            )
        )

    def test_documents_two_independent_approved_shas(self) -> None:
        self._assert_all_present(
            (
                "APPROVED_ECHO_INSTALLER_SHA",
                "APPROVED_ECHO_PRONUNCIATION_SHA",
            )
        )

    def test_documents_install_verify_promote_repair_examples(self) -> None:
        self._assert_all_present(
            (
                "PYTHONPATH=Scripts",
                "python3 -m echo_renderer.cli install",
                "python3 -m echo_renderer.cli verify",
                "python3 -m echo_renderer.cli promote",
                "python3 -m echo_renderer.cli repair",
                "make install-renderer",
                "make verify-renderer",
                "make promote-renderer",
                "make repair-renderer",
            )
        )

    def test_examples_use_separate_installer_and_source_worktrees(self) -> None:
        self._assert_all_present(
            (
                "--installer-worktree",
                "--source-worktree",
                "ECHO_RENDERER_SOURCE",
            )
        )
        worktree_add_count = self.guide_text.count("git worktree add")
        self.assertGreaterEqual(
            worktree_add_count,
            2,
            "expected at least two separate `git worktree add` examples "
            "(one for the installer worktree, one for the source worktree), "
            f"found {worktree_add_count}",
        )

    def test_documents_selector_semantics(self) -> None:
        self._assert_all_present(
            (
                "approved-renderer.json",
                "schemaVersion",
                "echoSourceSHA",
                "manifestSHA256",
                "--promote",
            )
        )
        self.assertIn(
            "no selector",
            self.guide_text.lower(),
            "guide should state that --promote / install --promote is only "
            "appropriate for a source with no selector yet",
        )

    def test_documents_model_non_attestation(self) -> None:
        self._assert_all_present(
            (
                "modelBytesAttested",
                "sharedEchoCache",
                "does not attest",
            )
        )

    def test_documents_no_narration_time_build(self) -> None:
        self.assertIn("narration-time", self.guide_text)

    def test_documents_repair_quarantine_behavior(self) -> None:
        self._assert_all_present(
            (
                ".quarantine-",
                "non-resumable",
            )
        )

    def test_documents_repair_never_writing_the_selector(self) -> None:
        # The CLI's repair subcommand has no --promote flag and hardcodes
        # promote=False (see test_cli.test_repair_has_no_promote_flag_in_its
        # _contract), so the guide must state repair never writes the selector.
        self.assertIn(
            "never writes the selector",
            self.guide_text.lower(),
            "guide should state plainly that repair never writes the selector",
        )
        self.assertNotIn(
            "promote-equivalent",
            self.guide_text,
            "guide must not describe a repair promote path that is "
            "unreachable through the documented CLI/Make interfaces",
        )

    def test_documents_make_override_variables(self) -> None:
        self._assert_all_present(
            (
                "ECHO_RENDERER_ROOT",
                "ECHO_BUILD_GATE",
                "--renderer-root",
                "--build-gate",
            )
        )

    def test_documents_no_automatic_cleanup(self) -> None:
        lowered = self.guide_text.lower()
        self.assertIn("no automatic", lowered)
        self.assertIn("cleanup", lowered)

    def test_documents_local_only_vs_future_signed_notarized_distribution(self) -> None:
        self._assert_all_present(
            (
                "local-only",
                "Developer ID",
            )
        )
        self.assertIn("notariz", self.guide_text.lower())

    def test_documents_hashes_are_not_a_security_boundary(self) -> None:
        lowered = self.guide_text.lower()
        self.assertIn("malicious", lowered)
        self.assertIn("accidental corruption", lowered)


class ArchitectureLinksGuideTests(unittest.TestCase):
    """ARCHITECTURE.md must point contributors at the operating guide."""

    def test_architecture_links_the_guide(self) -> None:
        architecture_text = _read(_ARCHITECTURE_PATH)
        self.assertIn(
            "docs/guides/versioned-echo-renderer.md",
            architecture_text,
            "ARCHITECTURE.md should link docs/guides/versioned-echo-renderer.md",
        )


if __name__ == "__main__":
    unittest.main()
