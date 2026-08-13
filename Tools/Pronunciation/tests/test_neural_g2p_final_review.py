import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/Pronunciation/neural_g2p_qualification.py"
LOCK_PATH = REPOSITORY_ROOT / "Tools/Pronunciation/mini_bart_g2p.lock.json"
VOCAB_PATH = REPOSITORY_ROOT / "EchoCore/Services/Narration/_kokoro_vocab.json"
GOLD_PATH = REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_gold.json"
SILVER_PATH = REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_silver.json"
PACK_PATH = (
    REPOSITORY_ROOT
    / "EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json"
)
CORPUS_PATH = (
    REPOSITORY_ROOT
    / "EchoTests/Fixtures/Pronunciation/neural_oov_candidates_v1.jsonl"
)


def load_tool():
    spec = importlib.util.spec_from_file_location(
        "neural_g2p_final_review_tool", TOOL_PATH
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def candidate(**overrides):
    row = {
        "caseID": "synthetic-final-review-001",
        "word": "Zyxqwf",
        "category": "adversarial",
        "context": "Zyxqwf appears in this synthetic context",
        "capitalization": "titlecase",
        "punctuation": "none",
        "sentencePosition": "initial",
        "labelStatus": "provisional",
        "provisionalExpectedIPA": "tˈɛst",
        "provenance": "synthetic",
    }
    row.update(overrides)
    return row


class NeuralG2PFinalReviewTests(unittest.TestCase):
    def test_locked_machine_receipt_recomputes_every_derived_field(self):
        tool = load_tool()
        resources = tool.load_governed_qualification_resources(
            LOCK_PATH, VOCAB_PATH, GOLD_PATH, SILVER_PATH, PACK_PATH
        )
        row = candidate()
        receipt = tool.build_machine_evidence_receipt(
            row,
            ["T EH1 S T", "T EH1 S T"],
            resources,
            receipt_id="machine-final-review-001",
        )

        validated = tool.validate_machine_evidence_receipts(
            [receipt], [row], resources
        )
        self.assertEqual("tˈɛst", validated[0]["selectedIPA"])
        self.assertEqual(
            [62, 156, 86, 61, 62], validated[0]["mappedTokenIDs"]
        )
        self.assertTrue(validated[0]["genuineDeterministicOOV"])
        self.assertTrue(validated[0]["stable"])
        self.assertTrue(validated[0]["automaticSelectionEligible"])

        for field, forged in (
            ("convertedOutputs", ["bæd", "bæd"]),
            ("mappedTokenIDs", [44, 72, 46]),
            ("genuineDeterministicOOV", False),
            ("automaticSelectionEligible", False),
        ):
            malformed = {**receipt, field: forged}
            malformed["receiptSHA256"] = tool.machine_evidence_receipt_digest(
                malformed
            )
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, "machine evidence"):
                    tool.validate_machine_evidence_receipts(
                        [malformed], [row], resources
                    )

    def test_runtime_states_are_derived_from_bound_measurements_and_receipts(self):
        tool = load_tool()
        model_identity, _ = tool._load_qualification_resources(LOCK_PATH, VOCAB_PATH)
        seed = tool.build_runtime_evidence_record(
            device_model="iPhone12,3",
            os_build="23F81",
            app_commit_sha="a" * 40,
            model_identity=model_identity,
            added_peak_rss_bytes=32 * 1024 * 1024,
            cold_preflight_milliseconds=750.0,
            sustained_preflight_milliseconds=40.0,
            kokoro_render_milliseconds=1000.0,
            oldest_supported_physical_iphone_attested=True,
            cancellation_passed=True,
            relaunch_passed=True,
            foreground_passed=True,
            lock_screen_passed=True,
            background_passed=True,
            primary_voice_id="af_heart",
            control_voice_id="am_adam",
            primary_voice_probe_sha256="1" * 64,
            control_voice_probe_sha256="2" * 64,
            listening_authority_sha256="3" * 64,
            listening_verdict="passed",
        )
        authority = tool.build_listening_evidence_authority(
            seed,
            listener_reference_sha256="4" * 64,
        )
        record = json.loads(json.dumps(seed))
        record["listening"]["authorityReceiptSHA256"] = authority["receiptSHA256"]
        record["receiptSHA256"] = tool.runtime_evidence_receipt_digest(record)

        states, identity = tool.derive_runtime_proof_states(
            record, authority, model_identity
        )
        self.assertEqual(
            {
                "performance": "VERIFIED",
                "device": "VERIFIED",
                "render": "VERIFIED",
                "listening": "VERIFIED",
            },
            states,
        )
        self.assertEqual(record["receiptSHA256"], identity["receiptSHA256"])
        self.assertEqual("iPhone12,3", identity["deviceModel"])
        self.assertEqual("23F81", identity["osBuild"])
        self.assertEqual("a" * 40, identity["appCommitSHA"])

        insufficient = dict(record)
        insufficient["performance"] = dict(record["performance"])
        insufficient["performance"]["coldPreflightMilliseconds"] = 2500.0
        insufficient["receiptSHA256"] = tool.runtime_evidence_receipt_digest(
            insufficient
        )
        insufficient_authority = tool.build_listening_evidence_authority(
            insufficient,
            listener_reference_sha256="4" * 64,
        )
        insufficient["listening"] = dict(insufficient["listening"])
        insufficient["listening"]["authorityReceiptSHA256"] = (
            insufficient_authority["receiptSHA256"]
        )
        insufficient["receiptSHA256"] = tool.runtime_evidence_receipt_digest(
            insufficient
        )
        failed, _ = tool.derive_runtime_proof_states(
            insufficient, insufficient_authority, model_identity
        )
        self.assertEqual("FAILED", failed["performance"])

        forged = {**record, "deviceModel": "iPhone99,9"}
        with self.assertRaisesRegex(ValueError, "runtime evidence receipt"):
            tool.derive_runtime_proof_states(forged, authority, model_identity)

        malformed_nested = {**record, "listening": 42}
        with self.assertRaisesRegex(ValueError, "listening record"):
            tool.derive_runtime_proof_states(
                malformed_nested, authority, model_identity
            )

        with self.assertRaisesRegex(ValueError, "authority"):
            tool.derive_runtime_proof_states(record, None, model_identity)

        waiting, missing_identity = tool.derive_runtime_proof_states(
            None, None, model_identity
        )
        self.assertEqual(
            {
                "performance": "NOT_PROVIDED",
                "device": "NOT_PROVIDED",
                "render": "NOT_PROVIDED",
                "listening": "NOT_PROVIDED",
            },
            waiting,
        )
        self.assertIsNone(missing_identity)

    def test_runtime_and_listening_evidence_require_distinct_external_files(self):
        tool = load_tool()
        model_identity, _ = tool._load_qualification_resources(LOCK_PATH, VOCAB_PATH)
        seed = tool.build_runtime_evidence_record(
            device_model="iPhone12,3",
            os_build="23F81",
            app_commit_sha="a" * 40,
            model_identity=model_identity,
            added_peak_rss_bytes=1,
            cold_preflight_milliseconds=1.0,
            sustained_preflight_milliseconds=1.0,
            kokoro_render_milliseconds=100.0,
            oldest_supported_physical_iphone_attested=True,
            cancellation_passed=True,
            relaunch_passed=True,
            foreground_passed=True,
            lock_screen_passed=True,
            background_passed=True,
            primary_voice_id="af_heart",
            control_voice_id="am_adam",
            primary_voice_probe_sha256="1" * 64,
            control_voice_probe_sha256="2" * 64,
            listening_authority_sha256="3" * 64,
            listening_verdict="passed",
        )
        authority = tool.build_listening_evidence_authority(
            seed,
            listener_reference_sha256="4" * 64,
        )
        seed["listening"]["authorityReceiptSHA256"] = authority["receiptSHA256"]
        seed["receiptSHA256"] = tool.runtime_evidence_receipt_digest(seed)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime_path = root / "runtime.json"
            authority_path = root / "authority.json"
            runtime_path.write_text(json.dumps(seed), encoding="utf-8")
            authority_path.write_text(json.dumps(authority), encoding="utf-8")

            states, identity = tool.load_external_runtime_evidence(
                runtime_path,
                authority_path,
                model_identity=model_identity,
            )
            self.assertTrue(all(value == "VERIFIED" for value in states.values()))
            self.assertEqual(
                authority["receiptSHA256"],
                identity["listeningAuthorityReceiptSHA256"],
            )

            malformed = dict(authority)
            malformed["runtimeReceiptSHA256"] = "0" * 64
            malformed["receiptSHA256"] = tool.listening_authority_receipt_digest(
                malformed
            )
            authority_path.write_text(json.dumps(malformed), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bind runtime evidence"):
                tool.load_external_runtime_evidence(
                    runtime_path,
                    authority_path,
                    model_identity=model_identity,
                )

    def test_candidate_contract_requires_governed_systematic_dimensions(self):
        tool = load_tool()
        row = candidate()
        for field in ("capitalization", "punctuation", "sentencePosition"):
            malformed = dict(row)
            del malformed[field]
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, "missing required fields"):
                    tool.validate_candidates([malformed])

        for field, value in (
            ("capitalization", "mixed"),
            ("punctuation", "unknown"),
            ("sentencePosition", "heading"),
        ):
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, field):
                    tool.validate_candidates([candidate(**{field: value})])

    def test_committed_fixture_covers_every_governed_variant(self):
        tool = load_tool()
        rows = tool.validate_candidates(tool._load_jsonl(CORPUS_PATH))
        coverage = tool.systematic_variant_counts(rows)
        self.assertGreaterEqual(len(rows), tool.MINIMUM_REVIEWED_CASES)
        for category in tool.CATEGORIES:
            self.assertGreaterEqual(
                sum(row["category"] == category for row in rows),
                tool.MINIMUM_CASES_PER_CATEGORY,
            )
        self.assertEqual(
            set(tool.CAPITALIZATION_VARIANTS), set(coverage["capitalization"])
        )
        self.assertEqual(
            set(tool.PUNCTUATION_VARIANTS), set(coverage["punctuation"])
        )
        self.assertEqual(
            set(tool.SENTENCE_POSITION_VARIANTS),
            set(coverage["sentencePosition"]),
        )
        self.assertTrue(
            all(
                count >= tool.MINIMUM_CASES_PER_SYSTEMATIC_VARIANT
                for axis in coverage.values()
                for count in axis.values()
            )
        )

    def test_locked_resources_match_lock_and_all_three_copy_phases(self):
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        project = (REPOSITORY_ROOT / "Echo.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        resources = REPOSITORY_ROOT / "EchoCore/Services/Narration/NeuralG2PResources"
        for artifact in lock["artifacts"]:
            resource = Path(artifact["path"]).name
            with self.subTest(resource=resource):
                content = (resources / resource).read_bytes()
                self.assertEqual(artifact["size"], len(content))
                self.assertEqual(artifact["sha256"], hashlib.sha256(content).hexdigest())
                self.assertIn(f"{resource} in iOS Resources", project)
                self.assertIn(f"{resource} in macOS Resources", project)
                self.assertIn(f"{resource} in Copy Narration Resources", project)

    def test_cli_exposes_evidence_files_but_no_direct_verified_flags(self):
        completed = subprocess.run(
            [sys.executable, str(TOOL_PATH), "qualification-status", "--help"],
            check=True,
            capture_output=True,
            text=True,
        )
        for option in (
            "--machine-evidence",
            "--runtime-evidence",
            "--listening-evidence-authority",
        ):
            self.assertIn(option, completed.stdout)
        self.assertNotIn("--performance-proof-state", completed.stdout)
        self.assertNotIn("--device-proof-state", completed.stdout)
        self.assertNotIn("--render-proof-state", completed.stdout)
        self.assertNotIn("--listening-proof-state", completed.stdout)


if __name__ == "__main__":
    unittest.main()
