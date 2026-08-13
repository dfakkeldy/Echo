import copy
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from Tools.Pronunciation.build_pronunciation_pack import (
    CMUDICT_COMMIT,
    GENERATOR_BEHAVIOR,
    _load_inputs,
    build_pack,
    canonical_json_bytes,
    choose_generation_timestamp,
    semantic_pack_version,
    verify_locked_file,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY_ROOT / "Tools" / "Pronunciation" / "build_pronunciation_pack.py"

KOKORO_VOCAB = {
    "vocab": {
        "ɑ": 1,
        "æ": 2,
        "ə": 3,
        "ʌ": 4,
        "ɔ": 5,
        "a": 6,
        "ʊ": 7,
        "ɪ": 8,
        "ɛ": 9,
        "ɚ": 10,
        "ɜ": 11,
        "ɹ": 12,
        "e": 13,
        "i": 14,
        "o": 15,
        "u": 16,
        "b": 17,
        "ʧ": 18,
        "d": 19,
        "ð": 20,
        "f": 21,
        "ɡ": 22,
        "h": 23,
        "ʤ": 24,
        "k": 25,
        "l": 26,
        "m": 27,
        "n": 28,
        "ŋ": 29,
        "p": 30,
        "s": 31,
        "ʃ": 32,
        "t": 33,
        "θ": 34,
        "v": 35,
        "w": 36,
        "j": 37,
        "z": 38,
        "ʒ": 39,
        "ˈ": 40,
        "ˌ": 41,
    }
}


def minimal_pack(**overrides):
    arguments = {
        "cmu_lines": ["APPLE  AE1 P AH0 L"],
        "gold": {},
        "silver": {},
        "kokoro_vocab": KOKORO_VOCAB,
        "generation_timestamp": "2026-07-29T12:00:00Z",
    }
    arguments.update(overrides)
    return build_pack(**arguments)


class PronunciationPackGeneratorTests(unittest.TestCase):
    def test_arpabet_stress_conversion_uses_stressed_and_unstressed_vowels(self):
        result = build_pack(
            cmu_lines=["TEST  T EH1 S T AH0", "MAYBE  M EY2 B IY0"],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual("tˈɛstə", result["entries"]["test"][0]["ipa"])
        self.assertEqual("mˌeɪbi", result["entries"]["maybe"][0]["ipa"])

    def test_alternate_suffixes_normalize_to_one_lowercase_spelling(self):
        result = build_pack(
            cmu_lines=[
                "RECORD(2)  R IH0 K AO1 R D",
                "RECORD  R EH1 K ER0 D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual(["record"], list(result["entries"]))
        self.assertEqual(
            ["ɹɪkˈɔɹd", "ɹˈɛkɚd"],
            [candidate["ipa"] for candidate in result["entries"]["record"]],
        )

    def test_inline_metadata_is_not_parsed_as_arpabet_for_sole_pronunciation(self):
        result = build_pack(
            cmu_lines=["AALTO  AA1 L T OW0 # name, finnish"],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual("ˈɑltoʊ", result["entries"]["aalto"][0]["ipa"])
        self.assertEqual(0, result["report"]["incompatible"])

    def test_annotated_alternate_remains_ambiguous_and_nonautomatic(self):
        result = build_pack(
            cmu_lines=[
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D # verb, alternate",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        candidates = result["entries"]["record"]
        self.assertEqual(2, len(candidates))
        self.assertTrue(
            all(not candidate["automaticWithoutContext"] for candidate in candidates)
        )
        self.assertTrue(
            all(
                candidate["validationStatus"]
                == "report-only-missing-sense-label"
                for candidate in candidates
            )
        )
        self.assertEqual(0, result["report"]["incompatible"])

    def test_candidate_id_is_stable_source_word_and_ipa_identity(self):
        result = minimal_pack()

        self.assertEqual(
            "cmudict.apple.d414e9ffc01e",
            result["entries"]["apple"][0]["candidateID"],
        )

    def test_existing_gold_word_is_report_only(self):
        result = minimal_pack(gold={"apple": {"DEFAULT": "ˈæpəl"}})

        self.assertNotIn("apple", result["entries"])
        self.assertEqual(1, result["report"]["existingGold"])
        self.assertEqual(0, result["report"]["existingSilver"])

    def test_existing_silver_word_is_report_only(self):
        result = minimal_pack(silver={"APPLE": "ˈæpəl"})

        self.assertNotIn("apple", result["entries"])
        self.assertEqual(0, result["report"]["existingGold"])
        self.assertEqual(1, result["report"]["existingSilver"])

    def test_ambiguous_cmudict_word_is_not_automatic(self):
        result = build_pack(
            cmu_lines=[
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        candidates = result["entries"]["record"]
        self.assertEqual(2, len(candidates))
        self.assertTrue(
            all(not item["automaticWithoutContext"] for item in candidates)
        )
        self.assertEqual(1, result["report"]["ambiguous"])

    def test_identical_variants_are_deduplicated_before_automatic_selection(self):
        result = build_pack(
            cmu_lines=[
                "APPLE  AE1 P AH0 L",
                "APPLE(2)  AE1 P AH0 L",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual(1, len(result["entries"]["apple"]))
        self.assertTrue(result["entries"]["apple"][0]["automaticWithoutContext"])

    def test_incompatible_candidate_is_rejected_whole(self):
        vocab_without_affricate = copy.deepcopy(KOKORO_VOCAB)
        del vocab_without_affricate["vocab"]["ʧ"]

        result = build_pack(
            cmu_lines=["CHIP  CH IH1 P", "APPLE  AE1 P AH0 L"],
            gold={},
            silver={},
            kokoro_vocab=vocab_without_affricate,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertNotIn("chip", result["entries"])
        self.assertIn("apple", result["entries"])
        self.assertEqual(1, result["report"]["incompatible"])

    def test_invalid_spelling_is_not_imported(self):
        result = build_pack(
            cmu_lines=["A.B.  EY1 B IY1", "CAN'T  K AE1 N T"],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual(["can't"], list(result["entries"]))

    def test_candidates_and_entries_are_sorted_independent_of_input_order(self):
        lines = [
            "ZEBRA  Z IY1 B R AH0",
            "APPLE  AE1 P AH0 L",
            "RECORD(2)  R IH0 K AO1 R D",
            "RECORD  R EH1 K ER0 D",
        ]

        forward = build_pack(
            cmu_lines=lines,
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )
        reverse = build_pack(
            cmu_lines=reversed(lines),
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual(canonical_json_bytes(forward), canonical_json_bytes(reverse))
        self.assertEqual(["apple", "record", "zebra"], list(forward["entries"]))

    def test_reviewed_frequency_band_is_attached_but_does_not_select_candidate(self):
        result = build_pack(
            cmu_lines=[
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            frequency_bands={"record": "veryCommon"},
            generation_timestamp="2026-07-29T12:00:00Z",
        )

        self.assertEqual(
            ["veryCommon", "veryCommon"],
            [candidate["frequencyBand"] for candidate in result["entries"]["record"]],
        )
        self.assertTrue(
            all(
                not candidate["automaticWithoutContext"]
                for candidate in result["entries"]["record"]
            )
        )

    def test_frequency_defaults_unknown_and_rejects_unreviewed_values(self):
        self.assertEqual(
            "unknown", minimal_pack()["entries"]["apple"][0]["frequencyBand"]
        )

        with self.assertRaisesRegex(ValueError, "frequency band"):
            minimal_pack(frequency_bands={"apple": "popular"})

    def test_frequency_keys_that_normalize_to_one_spelling_are_rejected_in_any_order(self):
        collisions = [
            [("APPLE", "common"), ("apple", "common")],
            [("apple", "common"), ("APPLE", "common")],
            [("record", "rare"), ("record(2)", "common")],
            [("record(2)", "common"), ("record", "rare")],
        ]

        for items in collisions:
            with self.subTest(items=items):
                with self.assertRaisesRegex(
                    ValueError, "normalize to duplicate spelling"
                ):
                    minimal_pack(frequency_bands=dict(items))

    def test_duplicate_raw_frequency_json_key_is_rejected_before_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            frequency = Path(temporary_directory) / "frequency.json"
            frequency.write_text(
                '{"apple":"common","apple":"rare"}\n',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                _load_inputs(
                    lock_path=Path("Tools/Pronunciation/cmudict.lock.json"),
                    gold_path=Path(
                        "EchoCore/Services/Narration/MisakiResources/us_gold.json"
                    ),
                    silver_path=Path(
                        "EchoCore/Services/Narration/MisakiResources/us_silver.json"
                    ),
                    vocab_path=Path(
                        "EchoCore/Services/Narration/_kokoro_vocab.json"
                    ),
                    frequency_path=frequency,
                )

    def test_candidate_contract_matches_the_runtime_loader_shape(self):
        candidate = minimal_pack()["entries"]["apple"][0]

        self.assertEqual(
            {
                "candidateID",
                "ipa",
                "lexicalClass",
                "senseLabel",
                "sourceID",
                "sourceTier",
                "kind",
                "automaticWithoutContext",
                "frequencyBand",
                "validationStatus",
            },
            set(candidate),
        )
        self.assertIsNone(candidate["lexicalClass"])
        self.assertIsNone(candidate["senseLabel"])
        self.assertEqual("cmudict", candidate["sourceID"])
        self.assertEqual("supplemental", candidate["sourceTier"])
        self.assertEqual("explicit", candidate["kind"])
        self.assertEqual("validated-automatic", candidate["validationStatus"])

    def test_each_candidate_source_resolves_to_exactly_one_pack_source(self):
        result = build_pack(
            cmu_lines=[
                "APPLE  AE1 P AH0 L",
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )
        sources_by_id = {
            source_id: [
                source
                for source in result["sources"]
                if source["sourceID"] == source_id
            ]
            for source_id in {
                candidate["sourceID"]
                for candidates in result["entries"].values()
                for candidate in candidates
            }
        }

        self.assertEqual(
            {
                "cmudict": [
                    {
                        "sourceID": "cmudict",
                        "snapshotID": f"cmudict@{CMUDICT_COMMIT}",
                        "role": "supplemental-candidates",
                        "sha256": result["sources"][0]["sha256"],
                    }
                ]
            },
            sources_by_id,
        )

    def test_ambiguous_unlabeled_candidates_are_report_only(self):
        candidates = build_pack(
            cmu_lines=[
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )["entries"]["record"]

        self.assertTrue(all(candidate["senseLabel"] is None for candidate in candidates))
        self.assertTrue(
            all(
                candidate["validationStatus"]
                == "report-only-missing-sense-label"
                for candidate in candidates
            )
        )
        self.assertTrue(
            all(not candidate["automaticWithoutContext"] for candidate in candidates)
        )

    def test_candidate_validation_metadata_participates_in_entries_identity(self):
        result = minimal_pack()
        changed_entries = copy.deepcopy(result["entries"])
        changed_entries["apple"][0]["validationStatus"] = (
            "report-only-missing-sense-label"
        )

        changed_digest = "sha256:" + hashlib.sha256(
            canonical_json_bytes(changed_entries)
        ).hexdigest()
        self.assertNotEqual(result["normalizedDataSHA256"], changed_digest)


class PronunciationPackIdentityTests(unittest.TestCase):
    def test_manifest_has_every_required_field_and_valid_audit_timestamp(self):
        result = minimal_pack()

        self.assertEqual(
            {
                "schemaVersion",
                "packVersion",
                "generatorVersion",
                "entryCount",
                "candidateCount",
                "normalizedDataSHA256",
                "kokoroVocabularyVersion",
                "dialect",
                "sources",
                "licenses",
                "requiredAcknowledgments",
                "generationTimestamp",
                "semanticIdentityPayload",
                "entries",
                "report",
            },
            set(result),
        )
        self.assertEqual(1, result["schemaVersion"])
        self.assertEqual("en-US", result["dialect"])
        self.assertEqual(
            "echo-pronunciation-pack-generator-v2", result["generatorVersion"]
        )
        self.assertRegex(result["packVersion"], r"^sha256:[0-9a-f]{64}$")
        self.assertRegex(result["normalizedDataSHA256"], r"^sha256:[0-9a-f]{64}$")
        self.assertRegex(
            result["kokoroVocabularyVersion"], r"^sha256:[0-9a-f]{64}$"
        )
        self.assertRegex(
            result["generationTimestamp"],
            r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$",
        )
        self.assertEqual(
            ["cmudict", "echo-us-gold", "echo-us-silver"],
            [source["sourceID"] for source in result["sources"]],
        )
        self.assertEqual(1, len(result["licenses"]))
        self.assertEqual(1, len(result["requiredAcknowledgments"]))

    def test_counts_and_normalized_hash_match_canonical_entries(self):
        result = build_pack(
            cmu_lines=[
                "APPLE  AE1 P AH0 L",
                "RECORD  R EH1 K ER0 D",
                "RECORD(2)  R IH0 K AO1 R D",
            ],
            gold={},
            silver={},
            kokoro_vocab=KOKORO_VOCAB,
            generation_timestamp="2026-07-29T12:00:00Z",
        )
        expected_digest = hashlib.sha256(
            canonical_json_bytes(result["entries"])
        ).hexdigest()

        self.assertEqual(2, result["entryCount"])
        self.assertEqual(3, result["candidateCount"])
        self.assertEqual(
            f"sha256:{expected_digest}", result["normalizedDataSHA256"]
        )

    def test_timestamp_does_not_change_semantic_pack_version(self):
        first = minimal_pack(generation_timestamp="2026-07-29T12:00:00Z")
        second = minimal_pack(generation_timestamp="2026-07-30T01:02:03Z")

        self.assertNotEqual(first["generationTimestamp"], second["generationTimestamp"])
        self.assertEqual(first["packVersion"], second["packVersion"])

    def test_normalized_content_changes_pack_version(self):
        first = minimal_pack()
        second = minimal_pack(cmu_lines=["APPLY  AH0 P L AY1"])

        self.assertNotEqual(first["normalizedDataSHA256"], second["normalizedDataSHA256"])
        self.assertNotEqual(first["packVersion"], second["packVersion"])

    def test_each_source_snapshot_identity_changes_pack_version(self):
        base = minimal_pack()
        for source_id in ("cmudict", "echo-us-gold", "echo-us-silver"):
            mutated_sources = copy.deepcopy(base["sources"])
            source = next(
                item for item in mutated_sources if item["sourceID"] == source_id
            )
            source["snapshotID"] += "-changed"

            changed = minimal_pack(sources=mutated_sources)
            with self.subTest(sourceID=source_id):
                self.assertNotEqual(base["packVersion"], changed["packVersion"])

    def test_excluded_gold_change_preserves_entries_but_rotates_provenance(self):
        adjective_default = minimal_pack(
            cmu_lines=["CONTENT  K AA1 N T EH0 N T"],
            gold={
                "content": {
                    "DEFAULT": "kəntˈɛnt",
                    "NOUN": "kˈɑntɛnt",
                }
            }
        )
        noun_default = minimal_pack(
            cmu_lines=["CONTENT  K AA1 N T EH0 N T"],
            gold={
                "content": {
                    "ADJ": "kəntˈɛnt",
                    "DEFAULT": "kˈɑntɛnt",
                    "NOUN": "kˈɑntɛnt",
                }
            }
        )
        adjective_gold = next(
            source
            for source in adjective_default["sources"]
            if source["sourceID"] == "echo-us-gold"
        )
        noun_gold = next(
            source
            for source in noun_default["sources"]
            if source["sourceID"] == "echo-us-gold"
        )

        self.assertEqual(adjective_default["entries"], noun_default["entries"])
        self.assertEqual(
            adjective_default["normalizedDataSHA256"],
            noun_default["normalizedDataSHA256"],
        )
        self.assertEqual(
            adjective_default["entryCount"], noun_default["entryCount"]
        )
        self.assertEqual(
            adjective_default["candidateCount"], noun_default["candidateCount"]
        )
        self.assertNotEqual(adjective_gold["sha256"], noun_gold["sha256"])
        self.assertNotEqual(
            adjective_default["packVersion"], noun_default["packVersion"]
        )

    def test_each_generator_behavior_version_changes_pack_version(self):
        base = minimal_pack()
        for key in GENERATOR_BEHAVIOR:
            changed_behavior = dict(GENERATOR_BEHAVIOR)
            changed_behavior[key] += "-changed"

            changed = minimal_pack(generator_behavior=changed_behavior)
            with self.subTest(generatorBehavior=key):
                self.assertNotEqual(base["packVersion"], changed["packVersion"])

    def test_pack_scoped_generator_behavior_contains_every_required_rule_version(self):
        behavior = minimal_pack()["semanticIdentityPayload"]["generatorBehavior"]

        self.assertEqual(
            {
                "generatorVersion",
                "normalizationPolicyVersion",
                "arpabetMappingVersion",
                "sourcePrecedencePolicyVersion",
                "automaticSelectionPolicyVersion",
                "candidateValidationPolicyVersion",
            },
            set(behavior),
        )
        self.assertEqual(GENERATOR_BEHAVIOR, behavior)

    def test_kokoro_vocabulary_identity_changes_pack_version_without_entry_change(self):
        extended_vocab = copy.deepcopy(KOKORO_VOCAB)
        extended_vocab["vocab"]["Q"] = 999

        base = minimal_pack()
        changed = minimal_pack(kokoro_vocab=extended_vocab)

        self.assertEqual(base["entries"], changed["entries"])
        self.assertNotEqual(
            base["kokoroVocabularyVersion"], changed["kokoroVocabularyVersion"]
        )
        self.assertNotEqual(base["packVersion"], changed["packVersion"])

    def test_display_metadata_and_report_presentation_are_nonsemantic(self):
        first = minimal_pack(
            licenses=[
                {
                    "sourceID": "cmudict",
                    "licenseID": "display-one",
                    "licensePath": "one",
                }
            ],
            required_acknowledgments=["display one"],
        )
        second = minimal_pack(
            licenses=[
                {
                    "sourceID": "cmudict",
                    "licenseID": "display-two",
                    "licensePath": "two",
                }
            ],
            required_acknowledgments=["display two"],
        )
        second["entryCount"] = 999
        second["candidateCount"] = 888
        second["report"] = {"presentation": "changed"}

        self.assertEqual(first["packVersion"], second["packVersion"])
        self.assertEqual(
            first["packVersion"],
            semantic_pack_version(second["semanticIdentityPayload"]),
        )

    def test_object_key_and_source_order_do_not_change_identity(self):
        base = minimal_pack()
        reversed_sources = list(reversed(base["sources"]))
        reversed_vocab = {
            "vocab": dict(reversed(list(KOKORO_VOCAB["vocab"].items())))
        }

        changed = minimal_pack(
            gold={"z": "z", "a": "a"},
            silver={"y": "y", "b": "b"},
            kokoro_vocab=reversed_vocab,
            sources=reversed_sources,
        )
        control = minimal_pack(
            gold={"a": "a", "z": "z"},
            silver={"b": "b", "y": "y"},
            sources=base["sources"],
        )

        self.assertEqual(control["packVersion"], changed["packVersion"])
        self.assertEqual(
            sorted(base["semanticIdentityPayload"]["sourceSnapshots"], key=lambda x: x["sourceID"]),
            base["semanticIdentityPayload"]["sourceSnapshots"],
        )

    def test_timestamp_preservation_requires_same_identity_and_valid_rfc3339(self):
        existing = minimal_pack(generation_timestamp="2026-07-29T12:00:00Z")

        self.assertEqual(
            "2026-07-29T12:00:00Z",
            choose_generation_timestamp(
                existing=existing,
                pack_version=existing["packVersion"],
                now="2026-07-30T01:02:03Z",
            ),
        )
        self.assertEqual(
            "2026-07-30T01:02:03Z",
            choose_generation_timestamp(
                existing={**existing, "generationTimestamp": "not-a-time"},
                pack_version=existing["packVersion"],
                now="2026-07-30T01:02:03Z",
            ),
        )
        self.assertEqual(
            "2026-07-30T01:02:03Z",
            choose_generation_timestamp(
                existing=existing,
                pack_version="sha256:" + "0" * 64,
                now="2026-07-30T01:02:03Z",
            ),
        )


class PronunciationPackInputAndCLITests(unittest.TestCase):
    def test_pinned_input_hash_failure_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "input"
            path.write_bytes(b"wrong bytes")

            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                verify_locked_file(path, "sha256:" + "0" * 64)

    def test_cli_check_detects_noncanonical_or_stale_expected_output(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            expected = root / "pack.json"

            expected.write_text("{}\n", encoding="utf-8")

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "check",
                    "--lock",
                    "Tools/Pronunciation/cmudict.lock.json",
                    "--gold",
                    "EchoCore/Services/Narration/MisakiResources/us_gold.json",
                    "--silver",
                    "EchoCore/Services/Narration/MisakiResources/us_silver.json",
                    "--vocab",
                    "EchoCore/Services/Narration/_kokoro_vocab.json",
                    "--expected",
                    str(expected),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("does not match deterministic regeneration", completed.stderr)

    def test_cli_build_writes_repository_readable_resource_mode(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "pack.json"

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "build",
                    "--lock",
                    "Tools/Pronunciation/cmudict.lock.json",
                    "--gold",
                    "EchoCore/Services/Narration/MisakiResources/us_gold.json",
                    "--silver",
                    "EchoCore/Services/Narration/MisakiResources/us_silver.json",
                    "--vocab",
                    "EchoCore/Services/Narration/_kokoro_vocab.json",
                    "--output",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertEqual(0o644, output.stat().st_mode & 0o777)

    def test_self_consistent_nonpinned_lock_cannot_authorize_another_source(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            cmudict = root / "cmudict.dict"
            license_path = root / "LICENSE"
            gold = root / "gold.json"
            silver = root / "silver.json"
            vocab = root / "vocab.json"
            lock = root / "lock.json"
            output = root / "pack.json"

            cmudict.write_text("ATTACK  AH0 T AE1 K\n", encoding="utf-8")
            license_path.write_text("attacker terms\n", encoding="utf-8")
            gold.write_text("{}\n", encoding="utf-8")
            silver.write_text("{}\n", encoding="utf-8")
            vocab.write_text(
                json.dumps(KOKORO_VOCAB, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            lock.write_text(
                json.dumps(
                    {
                        "sourceID": "cmudict",
                        "upstreamURL": "https://attacker.invalid/cmudict",
                        "commit": CMUDICT_COMMIT,
                        "dialect": "en-US",
                        "dictionary": {
                            "path": str(cmudict),
                            "sha256": "sha256:"
                            + hashlib.sha256(cmudict.read_bytes()).hexdigest(),
                        },
                        "license": {
                            "path": str(license_path),
                            "sha256": "sha256:"
                            + hashlib.sha256(license_path.read_bytes()).hexdigest(),
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "build",
                    "--lock",
                    str(lock),
                    "--gold",
                    str(gold),
                    "--silver",
                    str(silver),
                    "--vocab",
                    str(vocab),
                    "--output",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("frozen CMUdict source", completed.stderr)

    def test_input_bytes_are_read_once_and_same_bytes_drive_hashes_and_parsing(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            gold = root / "gold.json"
            silver = root / "silver.json"
            vocab = root / "vocab.json"
            frequency = root / "frequency.json"
            gold.write_bytes(b"{}\n")
            silver.write_bytes(b"{}\n")
            vocab.write_text(
                json.dumps(KOKORO_VOCAB, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            frequency.write_text('{"aalto":"rare"}\n', encoding="utf-8")

            dictionary_path = Path("ThirdParty/CMUdict/cmudict.dict")
            license_path = Path("ThirdParty/CMUdict/LICENSE")
            captured = {
                dictionary_path: dictionary_path.read_bytes(),
                license_path: license_path.read_bytes(),
                gold: b'{"apple":"test-only exclusion"}\n',
                silver: b"{}\n",
                vocab: json.dumps(
                    KOKORO_VOCAB, ensure_ascii=False, separators=(",", ":")
                ).encode("utf-8"),
                frequency: b'{"aalto":"common"}\n',
            }
            poisoned = {
                dictionary_path: b"ZZMALICIOUS  Z IY1\n",
                license_path: b"attacker terms\n",
                gold: b"{}\n",
                silver: b"{not json",
                vocab: b'{"vocab":{}}\n',
                frequency: b'{"aalto":"rare"}\n',
            }
            reads = {path: 0 for path in captured}
            real_read_bytes = Path.read_bytes

            def changing_read_bytes(path):
                if path not in captured:
                    return real_read_bytes(path)
                reads[path] += 1
                return captured[path] if reads[path] == 1 else poisoned[path]

            with mock.patch.object(Path, "read_bytes", changing_read_bytes):
                arguments, _ = _load_inputs(
                    lock_path=Path("Tools/Pronunciation/cmudict.lock.json"),
                    gold_path=gold,
                    silver_path=silver,
                    vocab_path=vocab,
                    frequency_path=frequency,
                )
                result = build_pack(
                    **arguments,
                    generation_timestamp="2026-07-29T12:00:00Z",
                )

        self.assertEqual({path: 1 for path in captured}, reads)
        self.assertNotIn("zzmalicious", result["entries"])
        self.assertNotIn("apple", result["entries"])
        self.assertEqual(
            "common", result["entries"]["aalto"][0]["frequencyBand"]
        )
        gold_source = next(
            source
            for source in result["sources"]
            if source["sourceID"] == "echo-us-gold"
        )
        self.assertEqual(
            "sha256:" + hashlib.sha256(captured[gold]).hexdigest(),
            gold_source["sha256"],
        )


class CheckedInPronunciationPackTests(unittest.TestCase):
    def test_pack_contains_all_comment_annotated_entries_and_ambiguities(self):
        pack = json.loads(
            (
                REPOSITORY_ROOT
                / "EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json"
            ).read_text(encoding="utf-8")
        )

        self.assertEqual(76125, pack["entryCount"])
        self.assertEqual(80407, pack["candidateCount"])
        self.assertEqual(0, pack["report"]["incompatible"])
        for word in (
            "aalburg",
            "aalsmeer",
            "aalto",
            "d'artagnan",
            "danglar",
            "danglars",
            "gdp",
            "hiv",
            "mcavinchey",
            "porthos",
            "spieth",
            "tubbercurry",
        ):
            with self.subTest(importedWord=word):
                self.assertIn(word, pack["entries"])

        for word in ("aalen", "sinn", "tiernan", "tierney", "spieth"):
            with self.subTest(ambiguousWord=word):
                candidates = pack["entries"][word]
                self.assertGreater(len(candidates), 1)
                self.assertTrue(
                    all(
                        not candidate["automaticWithoutContext"]
                        for candidate in candidates
                    )
                )
                self.assertTrue(
                    all(
                        candidate["validationStatus"]
                        == "report-only-missing-sense-label"
                        for candidate in candidates
                    )
                )


if __name__ == "__main__":
    unittest.main()
