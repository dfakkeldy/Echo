import hashlib
import importlib.util
import inspect
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
GOLD_PATH = REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_gold.json"
SILVER_PATH = REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_silver.json"
PACK_PATH = (
    REPOSITORY_ROOT
    / "EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json"
)
RECEIPT_PATH = REPOSITORY_ROOT / "docs/reports/neural-g2p-qualification.json"
REPORT_PATH = REPOSITORY_ROOT / "docs/reports/neural-g2p-qualification.md"
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


def _synthetic_word(case_id):
    digest = hashlib.sha256(case_id.encode("utf-8")).digest()
    suffix = "".join(chr(ord("a") + byte % 26) for byte in digest[:10])
    return f"synthetic{suffix}"


def _capitalized(word, variant):
    if variant == "lowercase":
        return word.lower()
    if variant == "titlecase":
        return word.capitalize()
    if variant == "uppercase":
        return word.upper()
    return word


def _context(word, punctuation="none", sentence_position="initial"):
    wrapped = {
        "none": word,
        "leading": f"“{word}",
        "trailing": f"{word},",
        "paired": f"“{word},",
    }[punctuation]
    if sentence_position == "initial":
        return f"{wrapped} appears in this synthetic public qualification sentence"
    if sentence_position == "medial":
        return f"A synthetic public probe places {wrapped} within this sentence"
    if sentence_position == "final":
        return f"A synthetic public qualification sentence ends with {wrapped}"
    return f"{wrapped} appears in this synthetic public qualification sentence"


def candidate(case_id="proper-noun-000", **overrides):
    capitalization = overrides.pop("capitalization", "titlecase")
    punctuation = overrides.pop("punctuation", "none")
    sentence_position = overrides.pop("sentencePosition", "initial")
    base_word = overrides.pop("word", _synthetic_word(case_id))
    word = _capitalized(base_word, capitalization)
    context = overrides.pop(
        "context", _context(word, punctuation, sentence_position)
    )
    row = {
        "caseID": case_id,
        "word": word,
        "category": "proper-noun",
        "context": context,
        "capitalization": capitalization,
        "punctuation": punctuation,
        "sentencePosition": sentence_position,
        "labelStatus": "provisional",
        "provisionalExpectedIPA": "tˈɛst",
        "provenance": "synthetic",
    }
    row.update(overrides)
    return row


def trusted_receipt(row, **overrides):
    receipt = {
        "receiptID": f"test-only-receipt-{row['caseID']}",
        "caseID": row["caseID"],
        "category": row["category"],
        "wordSHA256": hashlib.sha256(row["word"].encode("utf-8")).hexdigest(),
        "evidenceKind": "independent-human",
        "labelA": "tˈɛst",
        "labelB": "tˈɛst",
        "adjudicated": None,
        "reviewerARef": REVIEWER_A_REF,
        "reviewerBRef": REVIEWER_B_REF,
        "adjudicatorRef": None,
    }
    receipt.update(overrides)
    return receipt


def qualification_matrix():
    rows = []
    receipts = []
    capitalization_variants = ("lowercase", "titlecase", "uppercase")
    punctuation_variants = ("none", "leading", "trailing", "paired")
    position_variants = ("initial", "medial", "final")
    for category_index, category in enumerate(CATEGORIES):
        for index in range(100):
            capitalization = capitalization_variants[index % len(capitalization_variants)]
            punctuation = punctuation_variants[index % len(punctuation_variants)]
            sentence_position = position_variants[index % len(position_variants)]
            row = candidate(
                f"{category}-{index:03d}",
                category=category,
                capitalization=capitalization,
                punctuation=punctuation,
                sentencePosition=sentence_position,
            )
            rows.append(row)
            receipts.append(trusted_receipt(row))
    return rows, receipts


def machine_receipts(tool, rows, raw_outputs_by_case=None):
    resources = tool.load_governed_qualification_resources(
        LOCK_PATH, VOCAB_PATH, GOLD_PATH, SILVER_PATH, PACK_PATH
    )
    raw_outputs_by_case = raw_outputs_by_case or {}
    return [
        tool.build_machine_evidence_receipt(
            row,
            raw_outputs_by_case.get(row["caseID"], ["T EH1 S T", "T EH1 S T"]),
            resources,
            receipt_id=f"machine-{row['caseID']}",
        )
        for row in rows
    ]


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

    def test_complete_balanced_evidence_stays_fail_closed_without_governed_producer(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()
        machine = machine_receipts(tool, rows)
        with tempfile.TemporaryDirectory() as temporary:
            machine_path = Path(temporary) / "machine.jsonl"
            write_jsonl(machine_path, machine)
            result = tool.qualification_status(
                rows,
                receipts,
                authority_record(rows, receipts),
                LOCK_PATH,
                VOCAB_PATH,
                machine_evidence_path=machine_path,
            )

        self.assertEqual(3, result["schemaVersion"])
        self.assertEqual("FAILED", result["status"])
        self.assertEqual("FAILED", result["proofStates"]["human"])
        self.assertEqual("NOT_PROVIDED", result["proofStates"]["listening"])
        self.assertEqual(500, result["reviewedCount"])
        self.assertEqual(0, result["automaticCount"])
        self.assertEqual(0, result["correctAutomaticCount"])
        self.assertEqual(500, result["recomputedEligibleCount"])
        self.assertEqual(500, result["correctRecomputedEligibleCount"])
        self.assertEqual({category: 0 for category in CATEGORIES}, result["categoryCounts"])
        self.assertEqual(
            {category: 100 for category in CATEGORIES},
            result["recomputedEligibleCategoryCounts"],
        )
        self.assertIsNone(result["precision"])
        self.assertIsNone(result["wilson95LowerBound"])
        self.assertEqual("UNAVAILABLE_FAIL_CLOSED", result["governedMachineProducerState"])
        self.assertEqual(
            {
                "missingMachineEvidence": 0,
                "emptyOrUnmappable": 0,
                "unstable": 0,
                "notDeterministicOOV": 0,
            },
            result["invalidCounts"],
        )

    def test_absent_systematic_variants_cannot_reach_the_machine_gate(self):
        tool = load_tool()
        rows = []
        receipts = []
        for category in CATEGORIES:
            for index in range(100):
                row = candidate(
                    f"unbalanced-{category}-{index}",
                    category=category,
                    capitalization="lowercase",
                    punctuation="none",
                    sentencePosition="initial",
                )
                rows.append(row)
                receipts.append(trusted_receipt(row))

        result = tool.qualification_status(
            rows,
            receipts,
            authority_record(rows, receipts),
            LOCK_PATH,
            VOCAB_PATH,
        )

        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result["status"])
        self.assertEqual(
            0,
            result["systematicVariantCounts"]["capitalization"]["titlecase"],
        )
        self.assertFalse(
            result["systematicVariantResults"]["capitalization"]["titlecase"][
                "reviewCoverageGatePassed"
            ]
        )

    def test_precision_uses_selection_policy_not_raw_model_top_one(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()
        raw_outputs = {
            row["caseID"]: ["B AE1 D", "B AE1 D"] for row in rows[:5]
        }
        machine = machine_receipts(tool, rows, raw_outputs)
        with tempfile.TemporaryDirectory() as temporary:
            machine_path = Path(temporary) / "machine.jsonl"
            write_jsonl(machine_path, machine)
            result = tool.qualification_status(
                rows,
                receipts,
                authority_record(rows, receipts),
                LOCK_PATH,
                VOCAB_PATH,
                machine_evidence_path=machine_path,
            )

        self.assertEqual("FAILED", result["status"])
        self.assertIsNone(result["precision"])
        self.assertEqual(0, result["automaticCount"])
        self.assertEqual(500, result["recomputedEligibleCount"])
        self.assertEqual(495, result["correctRecomputedEligibleCount"])
        self.assertEqual(0.99, result["recomputedPrecision"])
        self.assertAlmostEqual(
            0.9768069002442693,
            result["recomputedWilson95LowerBound"],
        )

    def test_invalid_outputs_are_rejected_before_scoring(self):
        tool = load_tool()
        rows, receipts = qualification_matrix()
        probes = [
            candidate("adversarial-missing", category="adversarial"),
            candidate("adversarial-empty", category="adversarial"),
            candidate("adversarial-unstable", category="adversarial"),
            candidate(
                "adversarial-known",
                category="adversarial",
                word="and",
                capitalization="lowercase",
            ),
        ]
        rows.extend(probes)
        receipts.extend(trusted_receipt(row) for row in probes)
        raw_outputs = {
            probes[1]["caseID"]: ["", ""],
            probes[2]["caseID"]: ["T EH1 S T", "B AE1 D"],
        }
        machine = machine_receipts(tool, rows, raw_outputs)
        machine = [
            receipt
            for receipt in machine
            if receipt["caseID"] != probes[0]["caseID"]
        ]
        with tempfile.TemporaryDirectory() as temporary:
            machine_path = Path(temporary) / "machine.jsonl"
            write_jsonl(machine_path, machine)
            result = tool.qualification_status(
                rows,
                receipts,
                authority_record(rows, receipts),
                LOCK_PATH,
                VOCAB_PATH,
                machine_evidence_path=machine_path,
            )

        self.assertEqual("FAILED", result["status"])
        self.assertEqual(0, result["automaticCount"])
        self.assertEqual(500, result["recomputedEligibleCount"])
        self.assertEqual(1, result["invalidCounts"]["missingMachineEvidence"])
        self.assertEqual(1, result["invalidCounts"]["emptyOrUnmappable"])
        self.assertEqual(1, result["invalidCounts"]["unstable"])
        self.assertEqual(1, result["invalidCounts"]["notDeterministicOOV"])

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
                    candidate("first", word="sameword", capitalization="lowercase"),
                    candidate("second", word="sameword", capitalization="lowercase"),
                ],
                "duplicate governed category/word/systematic-variant",
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

    def test_machine_receipt_model_policy_and_resource_identities_are_recomputed(self):
        tool = load_tool()
        row = candidate()
        resources = tool.load_governed_qualification_resources(
            LOCK_PATH, VOCAB_PATH, GOLD_PATH, SILVER_PATH, PACK_PATH
        )
        valid = tool.build_machine_evidence_receipt(
            row,
            ["T EH1 S T", "T EH1 S T"],
            resources,
            receipt_id="machine-identity",
        )
        identity_mismatches = {
            "modelRevision": "0" * 40,
            "modelLockSHA256": "0" * 64,
            "vocabSHA256": "0" * 64,
            "goldLexiconSHA256": "0" * 64,
            "silverLexiconSHA256": "0" * 64,
            "pronunciationPackSHA256": "0" * 64,
            "conversionVersion": "different-conversion-v1",
            "validationVersion": "different-validation-v1",
            "selectionVersion": "different-selection-v1",
            "generatorID": "self-declared-other-generator",
        }

        for field, value in identity_mismatches.items():
            receipt = {**valid, field: value}
            receipt["receiptSHA256"] = tool.machine_evidence_receipt_digest(receipt)
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    ValueError, "does not match locked evaluation"
                ):
                    tool.validate_machine_evidence_receipts(
                        [receipt],
                        [row],
                        resources,
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

        self.assertNotIn("synthetic", encoded.lower())
        self.assertNotIn("context", encoded.lower())
        self.assertNotIn("tˈɛst", encoded)
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
        snapshots = {
            LOCK_PATH: ("model lock", LOCK_PATH.read_bytes()),
            VOCAB_PATH: ("Kokoro vocabulary", VOCAB_PATH.read_bytes()),
            GOLD_PATH: ("gold lexicon", GOLD_PATH.read_bytes()),
            SILVER_PATH: ("silver lexicon", SILVER_PATH.read_bytes()),
            PACK_PATH: ("pronunciation pack", PACK_PATH.read_bytes()),
        }
        reads = []

        def snapshot(path, *, name):
            resolved = Path(path)
            reads.append((resolved, name))
            expected_name, content = snapshots[resolved]
            self.assertEqual(expected_name, name)
            return content

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
            [(path, name) for path, (name, _) in snapshots.items()],
            reads,
        )
        self.assertEqual(
            hashlib.sha256(snapshots[LOCK_PATH][1]).hexdigest(),
            result["modelIdentity"]["lockSHA256"],
        )
        self.assertEqual(
            hashlib.sha256(snapshots[VOCAB_PATH][1]).hexdigest(),
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
        self.assertEqual("NOT_PROVIDED", receipt["proofStates"]["listening"])
        self.assertEqual(0, receipt["reviewedCount"])
        self.assertEqual("", completed.stderr)

    def test_runtime_proof_states_cannot_be_supplied_as_direct_strings(self):
        tool = load_tool()
        forbidden = {
            "performance_proof_state",
            "device_proof_state",
            "render_proof_state",
            "listening_proof_state",
        }
        self.assertTrue(
            forbidden.isdisjoint(inspect.signature(tool.qualification_status).parameters)
        )
        self.assertTrue(
            forbidden.isdisjoint(inspect.signature(tool.render_report).parameters)
        )

    def test_failed_runtime_proof_precedes_waiting_human(self):
        tool = load_tool()
        baseline = {
            "corpus": "CONTRACT_VALID",
            "human": "WAITING_FOR_HUMAN_LABELS",
            "performance": "NOT_PROVIDED",
            "device": "NOT_PROVIDED",
            "render": "NOT_PROVIDED",
            "listening": "NOT_PROVIDED",
        }

        self.assertEqual("WAITING_FOR_HUMAN_LABELS", tool.qualification_decision(baseline))
        for lane in ("performance", "listening"):
            with self.subTest(lane=lane):
                failed = {**baseline, lane: "FAILED"}
                self.assertEqual("FAILED", tool.qualification_decision(failed))

    def test_qualification_receipt_schema_v3_rejects_old_and_incompatible_versions(self):
        tool = load_tool()
        receipt = tool.qualification_status(
            [candidate()], [], None, LOCK_PATH, VOCAB_PATH
        )

        self.assertEqual(3, tool.QUALIFICATION_RECEIPT_SCHEMA_VERSION)
        self.assertEqual(3, receipt["schemaVersion"])
        self.assertEqual(receipt["proofStates"], tool.validate_qualification_receipt(receipt))
        for incompatible in (1, 2, 4, True, None):
            malformed = dict(receipt)
            if incompatible is None:
                del malformed["schemaVersion"]
            else:
                malformed["schemaVersion"] = incompatible
            with self.subTest(schema_version=incompatible):
                with self.assertRaisesRegex(ValueError, "receipt schema version"):
                    tool.validate_qualification_receipt(malformed)
                with self.assertRaisesRegex(ValueError, "receipt schema version"):
                    tool.render_report(malformed)

    def test_committed_waiting_receipt_and_report_match_the_governed_tool(self):
        tool = load_tool()
        expected = tool.qualification_status(
            tool.validate_candidates(tool._load_jsonl(CORPUS_PATH)),
            [],
            None,
            LOCK_PATH,
            VOCAB_PATH,
        )
        committed = json.loads(RECEIPT_PATH.read_text(encoding="utf-8"))

        self.assertEqual(expected, committed)
        self.assertEqual(3, committed["schemaVersion"])
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", committed["proofStates"]["human"])
        self.assertEqual("NOT_PROVIDED", committed["proofStates"]["listening"])
        self.assertTrue(
            REPORT_PATH.read_text(encoding="utf-8").startswith(
                tool.render_report(committed).rstrip() + "\n"
            )
        )

    def test_receipt_and_report_separate_all_closed_proof_states(self):
        tool = load_tool()
        receipt = tool.qualification_status(
            [candidate()], [], None, LOCK_PATH, VOCAB_PATH
        )

        self.assertEqual(
            {
                "corpus": "CONTRACT_VALID",
                "human": "WAITING_FOR_HUMAN_LABELS",
                "performance": "NOT_PROVIDED",
                "device": "NOT_PROVIDED",
                "render": "NOT_PROVIDED",
                "listening": "NOT_PROVIDED",
            },
            receipt.get("proofStates"),
        )

        report = tool.render_report(receipt)

        self.assertIn("Qualification status: `WAITING_FOR_HUMAN_LABELS`", report)
        self.assertIn("Corpus proof: `CONTRACT_VALID`", report)
        self.assertIn("Human proof: `WAITING_FOR_HUMAN_LABELS`", report)
        self.assertIn("Performance proof: `NOT_PROVIDED`", report)
        self.assertIn("Device proof: `NOT_PROVIDED`", report)
        self.assertIn("Render proof: `NOT_PROVIDED`", report)
        self.assertIn("Listening proof: `NOT_PROVIDED`", report)
        self.assertNotIn("Syntheticproper", report)

    def test_report_rejects_hostile_free_form_proof_states(self):
        tool = load_tool()
        receipt = tool.qualification_status(
            [candidate()], [], None, LOCK_PATH, VOCAB_PATH
        )
        baseline = {
            "corpus": "CONTRACT_VALID",
            "human": "WAITING_FOR_HUMAN_LABELS",
            "performance": "NOT_PROVIDED",
            "device": "NOT_PROVIDED",
            "render": "NOT_PROVIDED",
            "listening": "NOT_PROVIDED",
        }
        hostile_values = (
            "/Users/example/private/book.epub",
            "person@example.test",
            "`INJECTED`\n## Private evidence",
            ["NOT_PROVIDED"],
            {"state": "NOT_PROVIDED"},
        )

        for lane in baseline:
            for hostile in hostile_values:
                malformed = dict(receipt)
                malformed["proofStates"] = {**baseline, lane: hostile}
                with self.subTest(lane=lane, hostile=hostile):
                    try:
                        with self.assertRaisesRegex(ValueError, "proof state"):
                            tool.render_report(malformed)
                    except TypeError as error:
                        self.fail(f"proof-state validation leaked TypeError: {error}")


if __name__ == "__main__":
    unittest.main()
