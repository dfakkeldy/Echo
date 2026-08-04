import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/Pronunciation/neural_g2p_qualification.py"
CORPUS_PATH = (
    REPOSITORY_ROOT
    / "EchoTests/Fixtures/Pronunciation/neural_oov_candidates_v1.jsonl"
)
LOCK_PATH = REPOSITORY_ROOT / "Tools/Pronunciation/mini_bart_g2p.lock.json"
VOCAB_PATH = (
    REPOSITORY_ROOT
    / "EchoCore/Services/Narration/_kokoro_vocab.json"
)
CATEGORIES = (
    "proper-noun",
    "technical",
    "morphology",
    "loanword",
    "adversarial",
)
REVIEWER_A_REF = hashlib.sha256(b"test-only-reviewer-a").hexdigest()
REVIEWER_B_REF = hashlib.sha256(b"test-only-reviewer-b").hexdigest()


def load_tool():
    spec = importlib.util.spec_from_file_location(
        "neural_g2p_qualification", TOOL_PATH
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def candidate(case_id="proper-noun-000", **overrides):
    row = {
        "caseID": case_id,
        "word": f"Synthetic{case_id.replace('-', '')}",
        "category": "proper-noun",
        "context": "A synthetic token appears in this public test context.",
        "labelStatus": "provisional",
        "provisionalExpectedIPA": "təst",
        "provenance": "synthetic",
    }
    row.update(overrides)
    return row


def trusted_receipt(row, **overrides):
    selected_ipa = overrides.pop("selectedIPA", "təst")
    receipt = {
        "receiptID": f"test-only-receipt-{row['caseID']}",
        "caseID": row["caseID"],
        "category": row["category"],
        "wordSHA256": hashlib.sha256(row["word"].encode("utf-8")).hexdigest(),
        "evidenceKind": "independent-human",
        "labelA": "təst",
        "labelB": "təst",
        "adjudicated": None,
        "reviewerARef": REVIEWER_A_REF,
        "reviewerBRef": REVIEWER_B_REF,
        "adjudicatorRef": None,
        "rawModelTop1": "T EH1 S T",
        "convertedOutputs": [selected_ipa, selected_ipa],
        "mappedTokenIDs": [62, 83, 61, 62],
        "selectionOutcome": "automatic",
        "selectedIPA": selected_ipa,
        "modelRevision": "f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06",
        "modelLockSHA256": hashlib.sha256(LOCK_PATH.read_bytes()).hexdigest(),
        "vocabSHA256": hashlib.sha256(VOCAB_PATH.read_bytes()).hexdigest(),
        "conversionVersion": "mini-bart-arpabet-to-kokoro-v1",
        "validationVersion": "kokoro-vocab-validation-v1",
        "selectionVersion": "neural-oov-complete-selection-v1",
    }
    receipt.update(overrides)
    return receipt


def qualification_matrix():
    rows = []
    receipts = []
    for category in CATEGORIES:
        for index in range(100):
            row = candidate(
                f"{category}-{index:03d}",
                category=category,
                word=f"Synthetic{category.replace('-', '').title()}{index:03d}",
            )
            rows.append(row)
            receipts.append(trusted_receipt(row))
    return rows, receipts


def authority_digest(rows, receipts):
    payload = {
        "schemaVersion": 1,
        "authorizationPurpose": "neural-g2p-human-evidence-qualification",
        "candidateCases": rows,
        "trustedReceipts": receipts,
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def authority_record(rows, receipts, **overrides):
    authority = {
        "schemaVersion": 1,
        "authorityKind": "user-controlled-out-of-repository",
        "authorizationPurpose": "neural-g2p-human-evidence-qualification",
        "evidenceBundleSHA256": authority_digest(rows, receipts),
        "reviewerIndependenceAttested": True,
        "reviewerReferenceScheme": "sha256-v1",
    }
    authority.update(overrides)
    return authority


def write_jsonl(path, rows):
    path.write_text(
        "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


class NeuralG2PQualificationTests(unittest.TestCase):
    def test_00_qualification_tool_exists(self):
        self.assertTrue(TOOL_PATH.is_file(), "qualification tool is missing")

    def test_wilson_lower_bound_matches_hand_checked_values(self):
        tool = load_tool()

        self.assertAlmostEqual(0.9923756595384479, tool.wilson_lower_bound(500, 500))
        self.assertAlmostEqual(0.9768069002442693, tool.wilson_lower_bound(495, 500))
        self.assertEqual(0.0, tool.wilson_lower_bound(0, 0))

    def test_complete_balanced_independent_matrix_qualifies(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()

        result = tool.qualification_status(
            rows,
            receipts,
            authority_record(rows, receipts),
            LOCK_PATH,
            VOCAB_PATH,
        )

        self.assertEqual("QUALIFIED", result["status"])
        self.assertEqual("QUALIFIED", result["proofStates"]["human"])
        self.assertEqual(500, result["reviewedCount"])
        self.assertEqual(500, result["automaticCount"])
        self.assertEqual(500, result["correctAutomaticCount"])
        self.assertEqual({category: 100 for category in CATEGORIES}, result["categoryCounts"])
        self.assertEqual(1.0, result["precision"])
        self.assertAlmostEqual(0.9923756595384479, result["wilson95LowerBound"])
        self.assertEqual(
            {
                "duplicate": 0,
                "empty": 0,
                "unmappable": 0,
                "unstable": 0,
                "kokoroIncompatible": 0,
            },
            result["invalidCounts"],
        )

    def test_precision_uses_selection_policy_not_raw_model_top_one(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()
        for receipt in receipts[:5]:
            receipt["rawModelTop1"] = "T EH1 S T"
            receipt["convertedOutputs"] = ["bæd", "bæd"]
            receipt["mappedTokenIDs"] = [44, 72, 46]
            receipt["selectedIPA"] = "bæd"

        result = tool.qualification_status(
            rows,
            receipts,
            authority_record(rows, receipts),
            LOCK_PATH,
            VOCAB_PATH,
        )

        self.assertEqual("FAILED", result["status"])
        self.assertEqual(0.99, result["precision"])
        self.assertAlmostEqual(0.9768069002442693, result["wilson95LowerBound"])

    def test_invalid_outputs_are_rejected_before_scoring(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()
        probes = [
            {
                "convertedOutputs": ["", ""],
                "selectedIPA": "",
                "mappedTokenIDs": [],
            },
            {"mappedTokenIDs": [999]},
            {"convertedOutputs": ["təst", "bæd"]},
            {
                "convertedOutputs": ["💥", "💥"],
                "selectedIPA": "💥",
                "mappedTokenIDs": [],
            },
        ]
        for index, changes in enumerate(probes):
            row = candidate(
                f"adversarial-invalid-{index}",
                category="adversarial",
                word=f"SyntheticInvalid{index}",
            )
            rows.append(row)
            receipts.append(trusted_receipt(row, **changes))

        result = tool.qualification_status(
            rows,
            receipts,
            authority_record(rows, receipts),
            LOCK_PATH,
            VOCAB_PATH,
        )

        self.assertEqual("FAILED", result["status"])
        self.assertEqual(500, result["automaticCount"])
        self.assertEqual(1.0, result["precision"])
        self.assertEqual(1, result["invalidCounts"]["empty"])
        self.assertEqual(1, result["invalidCounts"]["unmappable"])
        self.assertEqual(1, result["invalidCounts"]["unstable"])
        self.assertEqual(1, result["invalidCounts"]["kokoroIncompatible"])

    def test_provisional_row_never_counts_even_when_its_values_match(self):
        tool = load_tool()
        row = candidate(
            provisionalExpectedIPA="təst",
        )

        result = tool.qualification_status(
            [row], [], None, LOCK_PATH, VOCAB_PATH
        )

        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result["status"])
        self.assertEqual(0, result["reviewedCount"])
        self.assertEqual(0, result["automaticCount"])
        self.assertIsNone(result["precision"])

    def test_contract_rejects_unknown_duplicate_and_non_unique_cases(self):
        tool = load_tool()
        probes = [
            ([candidate(category="general")], "category"),
            ([candidate(), candidate()], "duplicate caseID"),
            (
                [
                    candidate("first"),
                    candidate("second", word="SYNTHETICFIRST"),
                ],
                "duplicate category/word",
            ),
        ]

        for rows, message in probes:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    tool.validate_candidates(rows)

    def test_contract_enforces_public_permissive_or_synthetic_privacy(self):
        tool = load_tool()

        with self.assertRaisesRegex(ValueError, "provenance"):
            tool.validate_candidates([candidate(provenance="private")])
        with self.assertRaisesRegex(ValueError, "absolute path"):
            tool.validate_candidates([candidate(context="Read /Users/example/private.txt")])
        with self.assertRaisesRegex(ValueError, "sourceURL and license"):
            tool.validate_candidates([candidate(provenance="public-domain")])
        tool.validate_candidates(
            [
                candidate(
                    provenance="public-domain",
                    sourceURL="https://www.gutenberg.org/",
                    license="Public Domain",
                )
            ]
        )

    def test_duplicate_trusted_case_is_rejected_before_scoring(self):
        tool = load_tool()
        row = candidate()
        receipt = trusted_receipt(row)
        receipts = [receipt, {**receipt, "receiptID": "test-only-second"}]

        with self.assertRaisesRegex(ValueError, "multiple trusted receipts"):
            tool.qualification_status(
                [row],
                receipts,
                authority_record([row], receipts),
                LOCK_PATH,
                VOCAB_PATH,
            )

    def test_receipt_model_and_policy_identity_must_match(self):
        tool = load_tool()
        row = candidate()
        identity_mismatches = {
            "modelRevision": "0" * 40,
            "modelLockSHA256": "0" * 64,
            "vocabSHA256": "0" * 64,
            "conversionVersion": "different-conversion-v1",
            "validationVersion": "different-validation-v1",
            "selectionVersion": "different-selection-v1",
        }

        for field, value in identity_mismatches.items():
            receipt = trusted_receipt(row, **{field: value})
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    ValueError, "does not match qualification identities"
                ):
                    tool.qualification_status(
                        [row],
                        [receipt],
                        authority_record([row], [receipt]),
                        LOCK_PATH,
                        VOCAB_PATH,
                    )

    def test_receipt_is_content_free_and_carries_frozen_identities(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()

        result = tool.qualification_status(
            rows,
            receipts,
            authority_record(rows, receipts),
            LOCK_PATH,
            VOCAB_PATH,
        )
        encoded = json.dumps(result, sort_keys=True)

        self.assertNotIn("Synthetic", encoded)
        self.assertNotIn("context", encoded.lower())
        self.assertNotIn("təst", encoded)
        self.assertEqual("jonschneider/mini-bart-g2p", result["modelIdentity"]["model"])
        self.assertEqual(
            "f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06",
            result["modelIdentity"]["revision"],
        )
        self.assertRegex(result["corpusSHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(result["modelIdentity"]["lockSHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual("mini-bart-arpabet-to-kokoro-v1", result["conversionVersion"])
        self.assertEqual("kokoro-vocab-validation-v1", result["validationVersion"])
        self.assertEqual("neural-oov-complete-selection-v1", result["selectionVersion"])

    def test_external_evidence_rejects_unsafe_or_mismatched_files(self):
        tool = load_tool()
        row = candidate()
        receipt = trusted_receipt(row)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_target = root / "receipt-target.jsonl"
            write_jsonl(receipt_target, [receipt])
            authority_target = root / "authority-target.json"
            authority_target.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "authorityKind": "user-controlled-out-of-repository",
                        "authorizationPurpose": "neural-g2p-human-evidence-qualification",
                        "evidenceBundleSHA256": "0" * 64,
                        "reviewerIndependenceAttested": True,
                        "reviewerReferenceScheme": "sha256-v1",
                    }
                ),
                encoding="utf-8",
            )
            receipt_path = root / "receipts.jsonl"
            authority_path = root / "authority.json"

            receipt_path.symlink_to(receipt_target)
            with self.assertRaisesRegex(ValueError, "symlink"):
                tool.load_external_evidence(receipt_path, authority_target)
            receipt_path.unlink()

            os.link(receipt_target, receipt_path)
            with self.assertRaisesRegex(ValueError, "hardlink"):
                tool.load_external_evidence(receipt_path, authority_target)
            receipt_path.unlink()

            shutil.copyfile(receipt_target, receipt_path)
            os.link(authority_target, authority_path)
            with self.assertRaisesRegex(ValueError, "hardlink"):
                tool.load_external_evidence(receipt_path, authority_path)
            authority_path.unlink()

            with self.assertRaisesRegex(ValueError, "exact human evidence authority"):
                tool.load_external_evidence(receipt_path, authority_target, candidates=[row])

        repository_receipt = REPOSITORY_ROOT / "test-only-neural-receipt.jsonl"
        try:
            write_jsonl(repository_receipt, [receipt])
            with tempfile.TemporaryDirectory() as temporary:
                authority = Path(temporary) / "authority.json"
                authority.write_text("{}", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "outside the repository"):
                    tool.load_external_evidence(repository_receipt, authority)
        finally:
            repository_receipt.unlink(missing_ok=True)

    def test_external_evidence_propagates_changing_file_rejection(self):
        tool = load_tool()
        with mock.patch.object(
            tool,
            "_read_external_unique_regular_bytes",
            side_effect=ValueError("trusted receipts changed while it was read"),
        ):
            with self.assertRaisesRegex(ValueError, "changed while it was read"):
                tool.load_external_evidence(Path("/tmp/receipt"), Path("/tmp/authority"))

    def test_duplicate_reviewer_identity_cannot_satisfy_independent_review(self):
        tool = load_tool()
        row = candidate()
        receipt = trusted_receipt(row, reviewerBRef=REVIEWER_A_REF)

        with self.assertRaisesRegex(ValueError, "distinct reviewer references"):
            tool.qualification_status(
                [row],
                [receipt],
                authority_record([row], [receipt]),
                LOCK_PATH,
                VOCAB_PATH,
            )

    def test_adjudicator_must_be_distinct_from_both_reviewers(self):
        tool = load_tool()
        row = candidate()
        receipt = trusted_receipt(
            row,
            labelB="bæd",
            adjudicated="təst",
            adjudicatorRef=REVIEWER_A_REF,
        )

        with self.assertRaisesRegex(ValueError, "distinct adjudicator reference"):
            tool.qualification_status(
                [row],
                [receipt],
                authority_record([row], [receipt]),
                LOCK_PATH,
                VOCAB_PATH,
            )

    def test_human_authority_must_attest_reviewer_independence(self):
        tool = load_tool()
        row = candidate()
        receipt = trusted_receipt(row)
        untrusted = authority_record(
            [row], [receipt], reviewerIndependenceAttested=False
        )

        with self.assertRaisesRegex(ValueError, "reviewer independence attestation"):
            tool.qualification_status(
                [row], [receipt], untrusted, LOCK_PATH, VOCAB_PATH
            )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipts_path = root / "receipts.jsonl"
            authority_path = root / "authority.json"
            write_jsonl(receipts_path, [receipt])
            authority_path.write_text(json.dumps(untrusted), encoding="utf-8")
            with self.assertRaisesRegex(
                ValueError, "reviewer independence attestation"
            ):
                tool.load_external_evidence(
                    receipts_path, authority_path, candidates=[row]
                )

    def test_resource_identity_and_validation_use_one_stable_snapshot_each(self):
        tool = load_tool()
        lock_bytes = LOCK_PATH.read_bytes()
        vocab_bytes = VOCAB_PATH.read_bytes()
        reads = []

        def snapshot(path, *, name):
            resolved = Path(path)
            reads.append((resolved, name))
            if resolved == LOCK_PATH:
                return lock_bytes
            if resolved == VOCAB_PATH:
                return vocab_bytes
            raise AssertionError(f"unexpected resource path {resolved}")

        with mock.patch.object(
            tool,
            "_read_stable_regular_bytes",
            create=True,
            side_effect=snapshot,
        ):
            result = tool.qualification_status(
                [candidate()], [], None, LOCK_PATH, VOCAB_PATH
            )

        self.assertEqual(
            [(LOCK_PATH, "model lock"), (VOCAB_PATH, "Kokoro vocabulary")],
            reads,
        )
        self.assertEqual(
            hashlib.sha256(lock_bytes).hexdigest(),
            result["modelIdentity"]["lockSHA256"],
        )
        self.assertEqual(
            hashlib.sha256(vocab_bytes).hexdigest(),
            result["modelIdentity"]["vocabSHA256"],
        )

    def test_resource_snapshot_change_fails_closed(self):
        tool = load_tool()

        def changing_snapshot(path, *, name):
            if name == "Kokoro vocabulary":
                raise ValueError("Kokoro vocabulary changed while it was read")
            return Path(path).read_bytes()

        with mock.patch.object(
            tool,
            "_read_stable_regular_bytes",
            create=True,
            side_effect=changing_snapshot,
        ):
            with self.assertRaisesRegex(ValueError, "changed while it was read"):
                tool.qualification_status(
                    [candidate()], [], None, LOCK_PATH, VOCAB_PATH
                )

    def test_cli_waits_without_external_human_evidence(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(TOOL_PATH),
                "qualification-status",
                "--corpus",
                str(CORPUS_PATH),
                "--lock",
                str(LOCK_PATH),
                "--vocab",
                str(VOCAB_PATH),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        receipt = json.loads(completed.stdout)
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", receipt["status"])
        self.assertEqual(0, receipt["reviewedCount"])
        self.assertEqual("", completed.stderr)

    def test_receipt_and_report_separate_all_closed_proof_states(self):
        tool = load_tool()
        receipt = tool.qualification_status(
            [candidate()], [], None, LOCK_PATH, VOCAB_PATH
        )

        self.assertEqual(
            {
                "corpus": "CONTRACT_VALID",
                "human": "WAITING_FOR_HUMAN_LABELS",
                "performance": "NOT_RUN_NO_RUNTIME",
                "device": "NOT_RUN_NO_RUNTIME",
                "render": "NOT_RUN_NO_RUNTIME",
            },
            receipt.get("proofStates"),
        )

        report = tool.render_report(
            receipt,
            performance_proof_state="NOT_RUN_NO_RUNTIME",
            device_proof_state="NOT_RUN_NO_RUNTIME",
        )

        self.assertIn("Qualification status: `WAITING_FOR_HUMAN_LABELS`", report)
        self.assertIn("Corpus proof: `CONTRACT_VALID`", report)
        self.assertIn("Human proof: `WAITING_FOR_HUMAN_LABELS`", report)
        self.assertIn("Performance proof: `NOT_RUN_NO_RUNTIME`", report)
        self.assertIn("Device proof: `NOT_RUN_NO_RUNTIME`", report)
        self.assertIn("Render proof: `NOT_RUN_NO_RUNTIME`", report)
        self.assertNotIn("Syntheticproper", report)

    def test_report_rejects_hostile_free_form_proof_states(self):
        tool = load_tool()
        receipt = tool.qualification_status(
            [candidate()], [], None, LOCK_PATH, VOCAB_PATH
        )
        baseline = {
            "corpus": "CONTRACT_VALID",
            "human": "WAITING_FOR_HUMAN_LABELS",
            "performance": "NOT_RUN_NO_RUNTIME",
            "device": "NOT_RUN_NO_RUNTIME",
            "render": "NOT_RUN_NO_RUNTIME",
        }
        hostile_values = (
            "/Users/example/private/book.epub",
            "person@example.test",
            "`INJECTED`\n## Private evidence",
            ["NOT_RUN_NO_RUNTIME"],
            {"state": "NOT_RUN_NO_RUNTIME"},
        )

        for lane in baseline:
            for hostile in hostile_values:
                malformed = dict(receipt)
                malformed["proofStates"] = {**baseline, lane: hostile}
                with self.subTest(lane=lane, hostile=hostile):
                    try:
                        with self.assertRaisesRegex(ValueError, "proof state"):
                            tool.render_report(
                                malformed,
                                performance_proof_state="NOT_RUN_NO_RUNTIME",
                                device_proof_state="NOT_RUN_NO_RUNTIME",
                            )
                    except TypeError as error:
                        self.fail(f"proof-state validation leaked TypeError: {error}")

        for argument in ("performance_proof_state", "device_proof_state"):
            with self.subTest(argument=argument):
                values = {
                    "performance_proof_state": "NOT_RUN_NO_RUNTIME",
                    "device_proof_state": "NOT_RUN_NO_RUNTIME",
                }
                values[argument] = "/Users/example/private/evidence.json"
                with self.assertRaisesRegex(ValueError, "proof state"):
                    tool.render_report(receipt, **values)


if __name__ == "__main__":
    unittest.main()
