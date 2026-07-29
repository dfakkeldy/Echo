import dataclasses
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Tools.Pronunciation.pronunciation_corpus import (
    CONTEXTUAL_FAMILIES,
    REQUIRED_NAMED_SHAPES,
    ContextualCase,
    build_report,
    qualification_status,
    validate_contract,
    validate_distribution_works,
    validate_fixture_directory,
    validate_morphology,
    validate_named_regressions,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPOSITORY_ROOT / "EchoTests" / "Fixtures" / "Pronunciation"
SCRIPT = REPOSITORY_ROOT / "Tools" / "Pronunciation" / "pronunciation_corpus.py"
PACK = (
    REPOSITORY_ROOT
    / "EchoCore"
    / "Services"
    / "Narration"
    / "PronunciationResources"
    / "us_pronunciation_pack.json"
)


def contextual_case(**overrides):
    case = {
        "caseID": "candidate-content-001",
        "familyID": "content",
        "targetWord": "content",
        "precedingSentence": None,
        "targetSentence": "The synthetic sentence contains content.",
        "followingSentence": None,
        "labelStatus": "provisional",
        "labelA": None,
        "labelB": None,
        "adjudicated": None,
        "labelEvidenceKind": None,
        "labelEvidenceID": None,
        "provenance": "synthetic",
    }
    case.update(overrides)
    return case


def test_only_human_case(case_id, label, **overrides):
    """Build test-only validator input; it is not evidence."""
    family = "live" if label.startswith(("live.", "lives.")) else label.split(".", 1)[0]
    target_word = "lives" if label.startswith("lives.") else family
    case = contextual_case(
        caseID=case_id,
        familyID=family,
        targetWord=target_word,
        targetSentence=f"The synthetic sentence contains {target_word}.",
        labelStatus="human-labelled",
        labelA=label,
        labelB=label,
        labelEvidenceKind="independent-human",
        labelEvidenceID=f"test-only-receipt-{case_id}",
    )
    case.update(overrides)
    return case


def test_only_trusted_receipt(case, **overrides):
    """Build an explicitly trusted test input; it is not real evidence."""
    receipt = {
        "receiptID": case["labelEvidenceID"],
        "caseID": case["caseID"],
        "evidenceKind": case["labelEvidenceKind"],
        "labelA": case["labelA"],
        "labelB": case["labelB"],
        "adjudicated": case.get("adjudicated"),
    }
    receipt.update(overrides)
    return receipt


def test_only_authority_digest(cases, receipts):
    """Build a test-only binding digest; it is not real authority evidence."""
    payload = {
        "schemaVersion": 1,
        "authorizationPurpose": "pronunciation-human-evidence-qualification",
        "contextualCases": cases,
        "trustedReceipts": receipts,
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def complete_test_only_qualification_matrix():
    """Return synthetic rows and explicit test-only trust bindings."""
    distributions = [
        ("content", "content.material", 100),
        ("content", "content.satisfied", 100),
        ("read", "read.present", 100),
        ("read", "read.past", 100),
        ("live", "live.adjective", 50),
        ("live", "live.verb", 50),
        ("lives", "lives.noun", 50),
        ("lives", "lives.verb", 50),
        ("record", "record.noun", 100),
        ("record", "record.verb", 100),
    ]
    cases = []
    receipts = []
    for target_word, label, count in distributions:
        for index in range(count):
            case = test_only_human_case(
                f"qualification-{label}-{index}",
                label,
                targetWord=target_word,
                targetSentence=f"The synthetic sentence contains {target_word}.",
            )
            cases.append(case)
            receipts.append(test_only_trusted_receipt(case))
    return cases, receipts


def named_regression_matrix():
    rows = []
    for family in CONTEXTUAL_FAMILIES:
        target_word = "live" if family == "live" else family
        candidate = f"{target_word}.verb" if family in {"live", "record"} else None
        if family == "content":
            candidate = "content.material"
        elif family == "read":
            candidate = "read.present"
        for shape in REQUIRED_NAMED_SHAPES:
            rows.append(
                {
                    "caseID": f"named-{family}-{shape}",
                    "familyID": family,
                    "targetWord": target_word,
                    "shape": shape,
                    "precedingSentence": None,
                    "targetSentence": f"Synthetic {target_word} context.",
                    "followingSentence": None,
                    "expectedCandidateID": candidate,
                    "expectedDiscoveryState": "discovered",
                    "expectedAnalyzerState": "abstained",
                    "provenance": "synthetic",
                }
            )
    return rows


class PronunciationCorpusTests(unittest.TestCase):
    def test_contextual_case_uses_the_frozen_contract_fields(self):
        parsed = validate_contract([contextual_case()])[0]

        self.assertIsInstance(parsed, ContextualCase)
        self.assertEqual(
            [
                "case_id",
                "family_id",
                "target_word",
                "preceding_sentence",
                "target_sentence",
                "following_sentence",
                "label_status",
                "label_a",
                "label_b",
                "adjudicated",
                "label_evidence_kind",
                "label_evidence_id",
                "provenance",
            ],
            [field.name for field in dataclasses.fields(parsed)],
        )

    def test_contract_rejects_missing_required_fields(self):
        case = contextual_case()
        del case["targetSentence"]

        with self.assertRaisesRegex(ValueError, "missing required fields: targetSentence"):
            validate_contract([case])

    def test_contract_accepts_provisional_candidate_without_human_evidence(self):
        parsed = validate_contract([contextual_case()])

        self.assertEqual("provisional", parsed[0].label_status)
        self.assertIsNone(parsed[0].label_a)
        self.assertIsNone(parsed[0].label_evidence_id)

    def test_contract_rejects_every_human_evidence_field_on_provisional_rows(self):
        populated_values = {
            "labelA": "content.material",
            "labelB": "content.material",
            "adjudicated": "content.material",
            "labelEvidenceKind": "independent-human",
            "labelEvidenceID": "not-allowed-on-provisional",
        }

        for field, value in populated_values.items():
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    ValueError, "provisional rows cannot contain human evidence"
                ):
                    validate_contract([contextual_case(**{field: value})])

    def test_contract_rejects_invalid_family_candidate_pairs(self):
        case = test_only_human_case(
            "invalid-family-candidate",
            "record.noun",
            familyID="content",
            targetWord="content",
            targetSentence="Synthetic content appears here.",
        )

        with self.assertRaisesRegex(ValueError, "not a candidate for family content"):
            validate_contract([case])

    def test_contract_rejects_live_labels_for_lives_and_lives_labels_for_live(self):
        mismatches = [
            test_only_human_case(
                "live-with-lives-label",
                "lives.noun",
                targetWord="live",
                targetSentence="The synthetic event is live.",
            ),
            test_only_human_case(
                "lives-with-live-label",
                "live.verb",
                targetWord="lives",
                targetSentence="The synthetic tester lives nearby.",
            ),
        ]

        for case in mismatches:
            with self.subTest(caseID=case["caseID"]):
                with self.assertRaisesRegex(
                    ValueError, "not a candidate for targetWord"
                ):
                    validate_contract([case])

    def test_contract_rejects_unresolved_dual_label_disagreement(self):
        case = test_only_human_case(
            "unresolved-disagreement",
            "content.material",
            labelB="content.satisfied",
            adjudicated=None,
        )

        with self.assertRaisesRegex(ValueError, "requires adjudicated"):
            validate_contract([case])

    def test_contract_rejects_adjudication_that_contradicts_agreeing_labels(self):
        case = test_only_human_case(
            "contradictory-adjudication",
            "content.material",
            adjudicated="content.satisfied",
        )

        with self.assertRaisesRegex(ValueError, "must equal the agreeing labels"):
            validate_contract([case])

    def test_contract_requires_target_word_as_a_case_insensitive_whole_token(self):
        validate_contract(
            [
                contextual_case(
                    targetWord="CONTENT",
                    targetSentence="The synthetic CONTENT is present.",
                )
            ]
        )

        invalid_sentences = [
            "The synthetic sentence omits the required spelling.",
            "The synthetic recordable control is present.",
            "The synthetic prerecord control is present.",
            "The synthetic recordé control is present.",
            "The synthetic record\u0301 control is present.",
        ]
        for sentence in invalid_sentences:
            with self.subTest(sentence=sentence):
                with self.assertRaisesRegex(ValueError, "whole target token"):
                    validate_contract(
                        [
                            contextual_case(
                                familyID="record",
                                targetWord="record",
                                targetSentence=sentence,
                            )
                        ]
                    )

    def test_contract_rejects_human_label_without_external_evidence_receipt(self):
        case = test_only_human_case(
            "missing-evidence",
            "content.material",
            labelEvidenceID="",
        )

        with self.assertRaisesRegex(ValueError, "nonempty labelEvidenceID"):
            validate_contract([case])

    def test_contract_rejects_duplicate_case_ids(self):
        with self.assertRaisesRegex(ValueError, "duplicate caseID"):
            validate_contract([contextual_case(), contextual_case()])

    def test_contract_rejects_private_looking_paths_and_identity_keys(self):
        with self.subTest(kind="absolute path"):
            with self.assertRaisesRegex(ValueError, "absolute paths"):
                validate_contract(
                    [contextual_case(targetSentence="/private/example/context.txt")]
                )

        with self.subTest(kind="file URL"):
            with self.assertRaisesRegex(ValueError, "file://"):
                validate_contract(
                    [contextual_case(targetSentence="file:///private/example/context.txt")]
                )

        with self.subTest(kind="private metadata key"):
            with self.assertRaisesRegex(ValueError, "bookTitle"):
                validate_contract([contextual_case(bookTitle="Synthetic title")])

    def test_contract_rejects_embedded_local_paths_on_every_host(self):
        private_sentences = [
            "See file:///Users/example/private/context.txt for content.",
            "See /Users/example/private/context.txt for content.",
            "Synthetic content [link](/Users/example/private/)",
            "Synthetic content [private](/Users/example/)",
            "Synthetic content [private](/Users/) remains.",
            "Synthetic content [private](/home/) remains.",
            "Synthetic content [private](/Usersɐ/) remains.",
            "Synthetic content [private](/homé/) remains.",
            "Synthetic content [private](/kˈɑntɛnt/) remains.",
            "Use [content](/Usersɐ/) here.",
            "Use [content](/homé/) here.",
            "Use [content](/kˈɑntɛnt́/) here.",
            "Use [content](/data/) here.",
            "Use [content](/tmp/) here.",
            "Use [content](/kˈɑntɛnt/)/Users/example/private/ here.",
            "Use [content](/kˈɑntɛnt/)///Users/example/private/ here.",
            "Synthetic content references //server/share/private/",
            "Synthetic content references ///Users/example/private/",
            "Synthetic content references ////server/share/private/",
            "Synthetic content points to /",
            "Synthetic content points to C:\\",
            "Synthetic content points to C:/",
            "Synthetic content points to \\",
            r"See C:\Users\example\private\context.txt for content.",
            r"See \Users\example\private\context.txt for content.",
            r"See \\server\share\private\context.txt for content.",
        ]

        for sentence in private_sentences:
            with self.subTest(sentence=sentence):
                with self.assertRaisesRegex(ValueError, "file://|absolute paths"):
                    validate_contract([contextual_case(targetSentence=sentence)])

    def test_contract_preserves_committed_single_segment_override_markup(self):
        overrides = [
            ("content", "content", "Use [content](/kˈɑntɛnt/) here."),
            ("read", "read", "Use [read](/ɹˈɛd/) here."),
            ("live", "live", "Use [live](/lˈaIv/) here."),
            ("record", "record", "Use [record](/ɹəkˈɔɹd/) here."),
        ]

        for family_id, target_word, sentence in overrides:
            with self.subTest(familyID=family_id):
                validate_contract(
                    [
                        contextual_case(
                            caseID=f"override-{family_id}",
                            familyID=family_id,
                            targetWord=target_word,
                            targetSentence=sentence,
                        )
                    ]
                )

        validate_contract(
            [
                contextual_case(
                    caseID="override-content-casefold",
                    familyID="content",
                    targetWord="Content",
                    targetSentence="Use [CONTENT](/kˈɑntɛnt/) here.",
                )
            ]
        )

    def test_contract_rejects_source_metadata_on_synthetic_rows(self):
        malformed_metadata = [
            {"sourceURL": 17},
            {"license": ["not", "a", "license"]},
            {"sourceURL": "https://example.test/source", "license": "CC0-1.0"},
        ]

        for metadata in malformed_metadata:
            with self.subTest(metadata=metadata):
                with self.assertRaisesRegex(
                    ValueError, "synthetic provenance cannot contain"
                ):
                    validate_contract([contextual_case(**metadata)])

    def test_contract_requires_redistribution_metadata_for_non_synthetic_context(self):
        with self.assertRaisesRegex(ValueError, "sourceURL and license"):
            validate_contract([contextual_case(provenance="permissive")])

        validate_contract(
            [
                contextual_case(
                    provenance="permissive",
                    sourceURL="https://example.test/permissive-corpus",
                    license="CC0-1.0",
                )
            ]
        )

    def test_qualification_waits_for_independent_human_labels(self):
        result = qualification_status([contextual_case()])

        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)
        self.assertEqual(200, result.missing_family_counts["content"])
        self.assertEqual(50, result.missing_sense_counts["content.material"])

    def test_qualification_does_not_trust_a_self_declared_receipt_id(self):
        case = test_only_human_case("self-declared", "content.material")

        result = qualification_status([case])

        self.assertEqual(0, result.family_counts["content"])
        self.assertEqual(0, result.sense_counts["content.material"])
        self.assertEqual(200, result.missing_family_counts["content"])

    def test_qualification_rejects_receipts_without_a_separate_authority_binding(self):
        case = test_only_human_case("manufactured", "content.material")
        receipt = test_only_trusted_receipt(case)

        with self.assertRaisesRegex(ValueError, "authority"):
            qualification_status([case], trusted_receipts=[receipt])
        with self.assertRaisesRegex(ValueError, "authority"):
            qualification_status(
                [case],
                trusted_receipts=[receipt],
                trusted_authority_digest="0" * 64,
            )

    def test_qualification_counts_an_exact_explicit_trust_binding_once(self):
        case = test_only_human_case("explicitly-trusted", "content.material")
        receipt = test_only_trusted_receipt(case)

        result = qualification_status(
            [case],
            trusted_receipts=[receipt],
            trusted_authority_digest=test_only_authority_digest(
                [case],
                [receipt],
            ),
        )

        self.assertEqual(1, result.family_counts["content"])
        self.assertEqual(1, result.sense_counts["content.material"])
        self.assertEqual(199, result.missing_family_counts["content"])
        self.assertEqual(49, result.missing_sense_counts["content.material"])

    def test_qualification_rejects_lossy_contextual_case_input(self):
        raw_case = test_only_human_case(
            "permissive-direct-boundary",
            "content.material",
            labelEvidenceKind="source-verifiable",
            provenance="permissive",
            sourceURL="https://example.test/permissive-direct",
            license="CC0-1.0",
        )
        parsed_case = validate_contract([raw_case])[0]
        receipt = test_only_trusted_receipt(raw_case)

        with self.assertRaisesRegex(
            ValueError,
            "qualification_status requires raw contextual records",
        ):
            qualification_status(
                [parsed_case],
                trusted_receipts=[receipt],
                trusted_authority_digest=test_only_authority_digest(
                    [raw_case],
                    [receipt],
                ),
            )

        result = qualification_status(
            [raw_case],
            trusted_receipts=[receipt],
            trusted_authority_digest=test_only_authority_digest(
                [raw_case],
                [receipt],
            ),
        )
        self.assertEqual(1, result.family_counts["content"])
        self.assertEqual(1, result.sense_counts["content.material"])

    def test_qualification_rejects_duplicate_or_ambiguous_trusted_receipts(self):
        case = test_only_human_case("ambiguous-receipt", "content.material")
        receipt = test_only_trusted_receipt(case)
        probes = [
            (
                [receipt, dict(receipt)],
                "duplicate receiptID",
            ),
            (
                [
                    receipt,
                    test_only_trusted_receipt(
                        case,
                        receiptID="second-test-only-receipt",
                    ),
                ],
                "multiple trusted receipts for caseID",
            ),
        ]

        for receipts, message in probes:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    qualification_status(
                        [case],
                        trusted_receipts=receipts,
                        trusted_authority_digest=test_only_authority_digest(
                            [case],
                            receipts,
                        ),
                    )

    def test_qualification_rejects_one_receipt_claimed_by_multiple_cases(self):
        first = test_only_human_case("receipt-owner", "content.material")
        second = test_only_human_case(
            "receipt-reuser",
            "content.material",
            labelEvidenceID=first["labelEvidenceID"],
        )

        with self.assertRaisesRegex(ValueError, "cannot qualify multiple cases"):
            qualification_status(
                [first, second],
                trusted_receipts=[test_only_trusted_receipt(first)],
                trusted_authority_digest=test_only_authority_digest(
                    [first, second],
                    [test_only_trusted_receipt(first)],
                ),
            )

    def test_qualification_rejects_receipt_binding_mismatch(self):
        case = test_only_human_case("binding-mismatch", "content.material")
        receipt = test_only_trusted_receipt(
            case,
            labelB="content.satisfied",
            adjudicated="content.material",
        )

        with self.assertRaisesRegex(ValueError, "does not exactly match case"):
            qualification_status(
                [case],
                trusted_receipts=[receipt],
                trusted_authority_digest=test_only_authority_digest(
                    [case],
                    [receipt],
                ),
            )

    def test_qualification_reports_unbalanced_senses_even_when_family_total_is_met(self):
        cases = [
            test_only_human_case(f"material-{index}", "content.material")
            for index in range(175)
        ]
        cases.extend(
            test_only_human_case(f"satisfied-{index}", "content.satisfied")
            for index in range(25)
        )
        receipts = [test_only_trusted_receipt(case) for case in cases]

        result = qualification_status(
            cases,
            trusted_receipts=receipts,
            trusted_authority_digest=test_only_authority_digest(cases, receipts),
        )

        self.assertNotIn("content", result.missing_family_counts)
        self.assertEqual(25, result.missing_sense_counts["content.satisfied"])
        self.assertNotIn("content.material", result.missing_sense_counts)
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)

    def test_qualification_counts_correct_live_and_lives_spellings(self):
        cases = [
            test_only_human_case("correct-live-adjective", "live.adjective"),
            test_only_human_case("correct-live-verb", "live.verb"),
            test_only_human_case("correct-lives-noun", "lives.noun"),
            test_only_human_case("correct-lives-verb", "lives.verb"),
        ]
        receipts = [test_only_trusted_receipt(case) for case in cases]

        result = qualification_status(
            cases,
            trusted_receipts=receipts,
            trusted_authority_digest=test_only_authority_digest(cases, receipts),
        )

        self.assertEqual(4, result.family_counts["live"])
        self.assertEqual(1, result.sense_counts["live.adjective"])
        self.assertEqual(1, result.sense_counts["live.verb"])
        self.assertEqual(1, result.sense_counts["lives.noun"])
        self.assertEqual(1, result.sense_counts["lives.verb"])

    def test_complete_test_only_trust_matrix_reaches_qualified(self):
        cases, receipts = complete_test_only_qualification_matrix()

        result = qualification_status(
            cases,
            trusted_receipts=receipts,
            trusted_authority_digest=test_only_authority_digest(cases, receipts),
        )

        self.assertEqual("QUALIFIED", result.status)
        self.assertEqual({}, result.missing_family_counts)
        self.assertEqual({}, result.missing_sense_counts)

    def test_distribution_requires_ten_distinct_public_or_synthetic_works(self):
        works = [
            {"workID": f"synthetic-{index}", "provenance": "synthetic", "cases": 1}
            for index in range(9)
        ]

        with self.assertRaisesRegex(ValueError, "at least 10 works"):
            validate_distribution_works(works)

    def test_distribution_rejects_duplicate_work_ids(self):
        works = [
            {"workID": f"synthetic-{index}", "provenance": "synthetic", "cases": 1}
            for index in range(10)
        ]
        works[-1]["workID"] = works[0]["workID"]

        with self.assertRaisesRegex(ValueError, "duplicate workID"):
            validate_distribution_works(works)

    def test_distribution_requires_source_and_license_for_non_synthetic_work(self):
        works = [
            {"workID": f"synthetic-{index}", "provenance": "synthetic", "cases": 1}
            for index in range(9)
        ]
        works.append({"workID": "permissive-9", "provenance": "permissive", "cases": 1})

        with self.assertRaisesRegex(ValueError, "sourceURL and license"):
            validate_distribution_works(works)

    def test_morphology_requires_an_expected_derivation_for_automatic_rows(self):
        row = {
            "caseID": "morph-able-001",
            "word": "startable",
            "expectedBase": "start",
            "expectedRuleID": "morphology.able.exact-base.v1",
            "automatic": True,
        }

        with self.assertRaisesRegex(ValueError, "expected derivation result"):
            validate_morphology([row])

    def test_morphology_requires_frozen_candidate_identity_vectors(self):
        row = {
            "caseID": "morph-able-001",
            "word": "startable",
            "expectedBase": "start",
            "expectedRuleID": "morphology.able.exact-base.v1",
            "expectedIPA": "stˈɑɹtəbəl",
            "automatic": True,
        }

        with self.assertRaisesRegex(ValueError, "candidate identity"):
            validate_morphology([row])

    def test_morphology_negative_guards_cannot_claim_a_derivation(self):
        row = {
            "caseID": "morph-negative-001",
            "word": "Mirable",
            "expectedBase": "Mira",
            "expectedRuleID": None,
            "expectedIPA": None,
            "expectedCandidateID": None,
            "expectedCandidatePackVersion": None,
            "automatic": False,
        }

        with self.assertRaisesRegex(ValueError, "negative guard"):
            validate_morphology([row])

    def test_named_regressions_require_every_shape_for_each_family(self):
        rows = named_regression_matrix()
        rows.pop()

        with self.assertRaisesRegex(ValueError, "missing named regression shapes"):
            validate_named_regressions(rows)

    def test_named_regressions_require_explicit_discovery_and_analyzer_states(self):
        rows = named_regression_matrix()
        rows[0].pop("expectedAnalyzerState")

        with self.assertRaisesRegex(ValueError, "expectedAnalyzerState"):
            validate_named_regressions(rows)

    def test_named_regressions_enforce_live_spelling_candidate_mapping(self):
        probes = [
            ("live", "lives.noun"),
            ("lives", "live.verb"),
        ]
        for target_word, candidate in probes:
            rows = named_regression_matrix()
            live_row = next(row for row in rows if row["familyID"] == "live")
            live_row.update(
                {
                    "targetWord": target_word,
                    "targetSentence": f"Synthetic {target_word} context.",
                    "expectedCandidateID": candidate,
                }
            )
            with self.subTest(targetWord=target_word, candidate=candidate):
                with self.assertRaisesRegex(
                    ValueError, "not a candidate for targetWord"
                ):
                    validate_named_regressions(rows)

    def test_named_regressions_reject_malformed_target_override_paths(self):
        for payload in ("Usersɐ", "homé", "data", "tmp"):
            rows = named_regression_matrix()
            override_row = next(
                row
                for row in rows
                if row["familyID"] == "content"
                and row["shape"] == "override-markup"
            )
            override_row["targetSentence"] = (
                f"Use [content](/{payload}/) for this synthetic override."
            )

            with self.subTest(payload=payload):
                with self.assertRaisesRegex(ValueError, "absolute paths"):
                    validate_named_regressions(rows)

    def test_named_regressions_scan_paths_after_valid_override_span(self):
        suffixes = (
            "/Users/example/private/",
            "///Users/example/private/",
        )
        for suffix in suffixes:
            rows = named_regression_matrix()
            override_row = next(
                row
                for row in rows
                if row["familyID"] == "content"
                and row["shape"] == "override-markup"
            )
            override_row["targetSentence"] = (
                f"Use [content](/kˈɑntɛnt/){suffix} here."
            )

            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(ValueError, "absolute paths"):
                    validate_named_regressions(rows)

    def test_repository_fixtures_pass_contract_but_not_human_qualification(self):
        summary = validate_fixture_directory(FIXTURES)

        self.assertEqual("CONTRACT_VALID", summary["status"])
        self.assertEqual(36, summary["namedRegressions"])
        self.assertEqual(12, summary["contextualCandidates"])
        self.assertEqual(0, summary["humanLabelledCases"])
        self.assertFalse(summary["humanLabelledFixturePresent"])
        self.assertEqual(10, summary["distributionWorks"])
        self.assertEqual(14, summary["morphologyCases"])
        self.assertEqual(5, summary["candidateResearchSources"])

        result = qualification_status(summary["contextualRecords"])
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)

    def test_cli_preserves_permissive_provenance_and_uses_explicit_trust_file(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fixture_directory = temporary_root / "fixtures"
            shutil.copytree(FIXTURES, fixture_directory)
            case = test_only_human_case(
                "permissive-source-verifiable",
                "content.material",
                labelEvidenceKind="source-verifiable",
                provenance="permissive",
                sourceURL="https://example.test/permissive-corpus",
                license="CC0-1.0",
            )
            (fixture_directory / "contextual_families_v1.jsonl").write_text(
                json.dumps(case, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            receipt_path = temporary_root / "test-only-trusted-receipts.jsonl"
            receipt_path.write_text(
                json.dumps(
                    (receipt := test_only_trusted_receipt(case)),
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            authority_path = temporary_root / "human-evidence-authority.json"
            contextual_records = [
                json.loads(line)
                for line in (
                    fixture_directory
                    / "contextual_family_candidates_v1.jsonl"
                ).read_text(encoding="utf-8").splitlines()
                if line
            ] + [case]

            missing_authority = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "qualification-status",
                    "--fixtures",
                    str(fixture_directory),
                    "--trusted-receipts",
                    str(receipt_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            authority_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "authorityKind": "user-controlled-out-of-repository",
                        "authorizationPurpose":
                            "pronunciation-human-evidence-qualification",
                        "evidenceBundleSHA256": test_only_authority_digest(
                            contextual_records,
                            [receipt],
                        ),
                    },
                    sort_keys=True,
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "qualification-status",
                    "--fixtures",
                    str(fixture_directory),
                    "--trusted-receipts",
                    str(receipt_path),
                    "--human-evidence-authority",
                    str(authority_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            authority_target = temporary_root / "authority-target.json"
            authority_path.replace(authority_target)
            authority_path.symlink_to(authority_target)
            symlinked_authority = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "qualification-status",
                    "--fixtures",
                    str(fixture_directory),
                    "--trusted-receipts",
                    str(receipt_path),
                    "--human-evidence-authority",
                    str(authority_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, missing_authority.returncode)
        self.assertIn("human evidence authority", missing_authority.stderr)
        self.assertNotIn("Traceback", missing_authority.stderr)
        summary = json.loads(completed.stdout)
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", summary["status"])
        self.assertEqual(1, summary["familyCounts"]["content"])
        self.assertEqual(1, summary["senseCounts"]["content.material"])
        self.assertNotEqual(0, symlinked_authority.returncode)
        self.assertIn("cannot be a symlink", symlinked_authority.stderr)
        self.assertNotIn("Traceback", symlinked_authority.stderr)

    def test_cli_rejects_ambiguous_json_and_invalid_utf8_without_traceback(self):
        probes = [
            (
                b'{"caseID":"first","caseID":"second"}\n',
                "duplicate key caseID",
            ),
            (
                b'{"caseID":NaN}\n',
                "non-standard JSON constant NaN",
            ),
            (
                b'{"caseID":Infinity}\n',
                "non-standard JSON constant Infinity",
            ),
            (
                b'{"caseID":-Infinity}\n',
                "non-standard JSON constant -Infinity",
            ),
            (
                b"\xff\n",
                "not valid UTF-8",
            ),
        ]

        for content, expected_error in probes:
            with self.subTest(expected_error=expected_error):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    fixture_directory = Path(temporary_directory) / "fixtures"
                    shutil.copytree(FIXTURES, fixture_directory)
                    (
                        fixture_directory
                        / "contextual_family_candidates_v1.jsonl"
                    ).write_bytes(content)

                    completed = subprocess.run(
                        [
                            sys.executable,
                            str(SCRIPT),
                            "validate-contract",
                            "--fixtures",
                            str(fixture_directory),
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )

                self.assertNotEqual(0, completed.returncode)
                self.assertIn(
                    "contextual_family_candidates_v1.jsonl:1",
                    completed.stderr,
                )
                self.assertIn(expected_error, completed.stderr)
                self.assertNotIn("Traceback", completed.stderr)

    def test_cli_summaries_are_deterministic_json(self):
        validate_command = [
            sys.executable,
            str(SCRIPT),
            "validate-contract",
            "--fixtures",
            str(FIXTURES),
        ]
        qualification_command = [
            sys.executable,
            str(SCRIPT),
            "qualification-status",
            "--fixtures",
            str(FIXTURES),
        ]

        first_contract = subprocess.run(
            validate_command, check=True, capture_output=True, text=True
        ).stdout
        second_contract = subprocess.run(
            validate_command, check=True, capture_output=True, text=True
        ).stdout
        first_qualification = subprocess.run(
            qualification_command, check=True, capture_output=True, text=True
        ).stdout
        second_qualification = subprocess.run(
            qualification_command, check=True, capture_output=True, text=True
        ).stdout

        self.assertEqual(first_contract, second_contract)
        self.assertEqual(first_qualification, second_qualification)
        self.assertEqual("CONTRACT_VALID", json.loads(first_contract)["status"])
        self.assertEqual(
            "WAITING_FOR_HUMAN_LABELS",
            json.loads(first_qualification)["status"],
        )

    def test_program_report_separates_provisional_and_qualifying_counts(self):
        report = build_report(FIXTURES, PACK)

        self.assertEqual(
            {
                "imported": 76125,
                "ambiguous": 3982,
                "incompatible": 0,
                "existingGold": 36966,
                "existingSilver": 12021,
            },
            report["packCounts"],
        )
        self.assertEqual(
            {"content": 3, "live": 3, "read": 3, "record": 3},
            report["corpusCounts"]["byFamily"],
        )
        self.assertEqual(
            {"synthetic": 12},
            report["corpusCounts"]["byProvenance"],
        )
        self.assertEqual(12, report["evidenceCounts"]["provisionalCandidates"])
        self.assertEqual(0, report["evidenceCounts"]["qualifyingHumanLabelled"])
        self.assertEqual(0, report["evidenceCounts"]["adjudicated"])
        self.assertEqual(
            {"resolved": 0, "advisory": 13, "abstained": 23},
            report["deterministicCounts"],
        )
        self.assertEqual(
            {
                "morphology.able.exact-base.v1": 2,
                "morphology.able.silent-e.v1": 1,
                "morphology.ible.exact-base.v1": 2,
                "negative": 9,
            },
            report["corpusCounts"]["byMorphologyRule"],
        )
        self.assertEqual(
            "WAITING_FOR_HUMAN_LABELS",
            report["corpusQualificationStatus"],
        )
        self.assertEqual(
            {"content": 200, "live": 200, "read": 200, "record": 200},
            report["missingFamilyCounts"],
        )
        self.assertEqual(
            "unavailable-no-approved-source",
            report["frequencyBandReport"],
        )

    def test_program_report_cli_is_byte_identical_across_runs(self):
        command = [
            sys.executable,
            str(SCRIPT),
            "report",
            "--fixtures",
            str(FIXTURES),
            "--pack",
            str(PACK),
        ]

        first = subprocess.run(
            command, check=True, capture_output=True, text=True
        ).stdout
        second = subprocess.run(
            command, check=True, capture_output=True, text=True
        ).stdout

        self.assertEqual(first, second)
        self.assertEqual(build_report(FIXTURES, PACK), json.loads(first))

    def test_make_program_report_stdout_is_one_json_value(self):
        completed = subprocess.run(
            ["make", "pronunciation-program-report"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(build_report(FIXTURES, PACK), json.loads(completed.stdout))


if __name__ == "__main__":
    unittest.main()
