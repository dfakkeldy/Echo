import dataclasses
import json
import subprocess
import sys
import unittest
from pathlib import Path

from Tools.Pronunciation.pronunciation_corpus import (
    CONTEXTUAL_FAMILIES,
    REQUIRED_NAMED_SHAPES,
    ContextualCase,
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


def contextual_case(**overrides):
    case = {
        "caseID": "candidate-content-001",
        "familyID": "content",
        "targetWord": "content",
        "precedingSentence": None,
        "targetSentence": "The synthetic sentence contains the target word.",
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
    """Build validator input only; this is never corpus evidence."""
    case = contextual_case(
        caseID=case_id,
        labelStatus="human-labelled",
        labelA=label,
        labelB=label,
        labelEvidenceKind="independent-human",
        labelEvidenceID=f"test-only-external-receipt-{case_id}",
    )
    case.update(overrides)
    return case


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
        )

        with self.assertRaisesRegex(ValueError, "not a candidate for family content"):
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

    def test_qualification_counts_only_receipted_human_labelled_rows(self):
        cases = [
            contextual_case(caseID="provisional-not-counted"),
            test_only_human_case("human-counted", "content.material"),
        ]

        result = qualification_status(cases)

        self.assertEqual(1, result.family_counts["content"])
        self.assertEqual(1, result.sense_counts["content.material"])
        self.assertEqual(199, result.missing_family_counts["content"])
        self.assertEqual(49, result.missing_sense_counts["content.material"])

    def test_qualification_reports_unbalanced_senses_even_when_family_total_is_met(self):
        cases = [
            test_only_human_case(f"material-{index}", "content.material")
            for index in range(175)
        ]
        cases.extend(
            test_only_human_case(f"satisfied-{index}", "content.satisfied")
            for index in range(25)
        )

        result = qualification_status(cases)

        self.assertNotIn("content", result.missing_family_counts)
        self.assertEqual(25, result.missing_sense_counts["content.satisfied"])
        self.assertNotIn("content.material", result.missing_sense_counts)
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)

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

    def test_morphology_negative_guards_cannot_claim_a_derivation(self):
        row = {
            "caseID": "morph-negative-001",
            "word": "Mirable",
            "expectedBase": "Mira",
            "expectedRuleID": None,
            "expectedIPA": None,
            "automatic": False,
        }

        with self.assertRaisesRegex(ValueError, "negative guard"):
            validate_morphology([row])

    def test_named_regressions_require_every_shape_for_each_family(self):
        rows = []
        for family, candidates in CONTEXTUAL_FAMILIES.items():
            candidate = sorted(candidates)[0]
            for shape in REQUIRED_NAMED_SHAPES:
                rows.append(
                    {
                        "caseID": f"named-{family}-{shape}",
                        "familyID": family,
                        "targetWord": "live" if family == "live" else family,
                        "shape": shape,
                        "precedingSentence": None,
                        "targetSentence": "Synthetic target context.",
                        "followingSentence": None,
                        "expectedCandidateID": candidate,
                        "expectedOutcome": "review",
                        "provenance": "synthetic",
                    }
                )
        rows.pop()

        with self.assertRaisesRegex(ValueError, "missing named regression shapes"):
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

        result = qualification_status(summary["contextualCases"])
        self.assertEqual("WAITING_FOR_HUMAN_LABELS", result.status)

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


if __name__ == "__main__":
    unittest.main()
