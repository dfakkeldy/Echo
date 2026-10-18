from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from echo_renderer.identity import ModelPolicy
from echo_renderer.model_policy import read_model_policy


SOURCE_PATH = Path("EchoCore/Services/Narration/OnnxKokoroEngine.swift")
VALID_REVISION = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"


class ModelPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source_root = Path(self.temporary.name).resolve()

    def _write_source(self, contents: str) -> None:
        source = self.source_root / SOURCE_PATH
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(contents, encoding="utf-8")

    def test_extracts_the_unique_model_policy_literals(self):
        self._write_source(
            """
            private nonisolated static let modelRevision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
            nonisolated static let expectedModelBytes = 163_234_740
            """
        )

        policy = read_model_policy(self.source_root)

        self.assertEqual(
            policy,
            ModelPolicy(
                revision="1939ad2a8e416c0acfeecc08a694d14ef25f2231",
                expected_byte_count=163_234_740,
                delivery_mode="sharedEchoCache",
                bytes_attested=False,
            ),
        )

    def test_extracts_the_live_renderer_model_policy(self):
        repository_root = Path(__file__).parents[3]

        self.assertEqual(
            read_model_policy(repository_root),
            ModelPolicy(
                revision="1939ad2a8e416c0acfeecc08a694d14ef25f2231",
                expected_byte_count=163_234_740,
                delivery_mode="sharedEchoCache",
                bytes_attested=False,
            ),
        )

    def test_rejects_zero_or_multiple_revision_literals(self):
        revision = (
            f'private nonisolated static let modelRevision = "{VALID_REVISION}"\n'
        )
        expected_bytes = "nonisolated static let expectedModelBytes = 1\n"
        cases = (expected_bytes, revision + revision + expected_bytes)

        for contents in cases:
            with self.subTest(contents=contents):
                self._write_source(contents)
                with self.assertRaises(ValueError):
                    read_model_policy(self.source_root)

    def test_rejects_zero_or_multiple_expected_byte_literals(self):
        revision = (
            f'private nonisolated static let modelRevision = "{VALID_REVISION}"\n'
        )
        expected_bytes = "nonisolated static let expectedModelBytes = 1\n"
        cases = (revision, revision + expected_bytes + expected_bytes)

        for contents in cases:
            with self.subTest(contents=contents):
                self._write_source(contents)
                with self.assertRaises(ValueError):
                    read_model_policy(self.source_root)

    def test_rejects_nonpositive_and_malformed_expected_byte_literals(self):
        revision = (
            f'private nonisolated static let modelRevision = "{VALID_REVISION}"\n'
        )
        invalid_literals = ("0", "-1", "1__000", "1_", "+1")

        for literal in invalid_literals:
            with self.subTest(literal=literal):
                self._write_source(
                    revision
                    + f"nonisolated static let expectedModelBytes = {literal}\n"
                )
                with self.assertRaises(ValueError):
                    read_model_policy(self.source_root)

    def test_rejects_revision_literals_that_are_not_lowercase_commit_shas(self):
        malformed_revisions = (
            VALID_REVISION[:-1],
            VALID_REVISION.upper(),
            "g" * 40,
            r"\(modelRevisionFromEnvironment)",
            r"\u0031" * 40,
        )

        for revision in malformed_revisions:
            with self.subTest(revision=revision):
                self._write_source(
                    "private nonisolated static let modelRevision = "
                    f'"{revision}"\n'
                    "nonisolated static let expectedModelBytes = 1\n"
                )
                with self.assertRaises(ValueError):
                    read_model_policy(self.source_root)

    def test_rejects_declarations_embedded_in_comments_or_other_syntax(self):
        self._write_source(
            """
            // private nonisolated static let modelRevision = "commented"
            let text = "nonisolated static let expectedModelBytes = 123"
            """
        )

        with self.assertRaises(ValueError):
            read_model_policy(self.source_root)

    def test_extraction_anchors_on_assignments_not_a_repeated_doc_comment_literal(self):
        # Mirrors the real file's line-86 doc comment, which repeats
        # `163_234_740` in prose immediately above the `modelRevision`
        # assignment. A bare-value literal search for the byte count would
        # find this synthetic fixture's comment AND its real assignment and
        # incorrectly report two expected-byte matches.
        self._write_source(
            f"""
            /// Immutable commit pin. Validated at pin time:
            /// 163_234_740 B · sha256 deadbeef…cafef00d (onnx/model_fp16.onnx).
            private nonisolated static let modelRevision = "{VALID_REVISION}"
            nonisolated static let expectedModelBytes = 163_234_740
            """
        )

        policy = read_model_policy(self.source_root)

        self.assertEqual(
            policy,
            ModelPolicy(
                revision=VALID_REVISION,
                expected_byte_count=163_234_740,
                delivery_mode="sharedEchoCache",
                bytes_attested=False,
            ),
        )

    def test_error_messages_name_the_source_file_and_assignment_pattern(self):
        source_path = self.source_root / SOURCE_PATH

        self._write_source("// no declarations here\n")
        with self.assertRaises(ValueError) as revision_error:
            read_model_policy(self.source_root)
        revision_message = str(revision_error.exception)
        self.assertIn(str(source_path), revision_message)
        self.assertIn('modelRevision =', revision_message)

        self._write_source(
            f'private nonisolated static let modelRevision = "{VALID_REVISION}"\n'
        )
        with self.assertRaises(ValueError) as bytes_error:
            read_model_policy(self.source_root)
        bytes_message = str(bytes_error.exception)
        self.assertIn(str(source_path), bytes_message)
        self.assertIn('expectedModelBytes =', bytes_message)
