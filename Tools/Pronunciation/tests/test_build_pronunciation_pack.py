import copy
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Tools.Pronunciation.build_pronunciation_pack import (
    CMUDICT_COMMIT,
    GENERATOR_BEHAVIOR,
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

    def test_candidate_contract_matches_the_runtime_loader_shape(self):
        candidate = minimal_pack()["entries"]["apple"][0]

        self.assertEqual(
            {
                "candidateID",
                "ipa",
                "sourceID",
                "sourceTier",
                "kind",
                "automaticWithoutContext",
                "frequencyBand",
            },
            set(candidate),
        )
        self.assertEqual("cmudict", candidate["sourceID"])
        self.assertEqual("supplemental", candidate["sourceTier"])
        self.assertEqual("explicit", candidate["kind"])


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
            "echo-pronunciation-pack-generator-v1", result["generatorVersion"]
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

    def test_each_generator_behavior_version_changes_pack_version(self):
        base = minimal_pack()
        for key in GENERATOR_BEHAVIOR:
            changed_behavior = dict(GENERATOR_BEHAVIOR)
            changed_behavior[key] += "-changed"

            changed = minimal_pack(generator_behavior=changed_behavior)
            with self.subTest(generatorBehavior=key):
                self.assertNotEqual(base["packVersion"], changed["packVersion"])

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
            cmudict = root / "cmudict.dict"
            license_path = root / "LICENSE"
            gold = root / "gold.json"
            silver = root / "silver.json"
            vocab = root / "vocab.json"
            lock = root / "lock.json"
            expected = root / "pack.json"

            cmudict.write_text("APPLE  AE1 P AH0 L\n", encoding="utf-8")
            license_path.write_text("fixture license\n", encoding="utf-8")
            gold.write_text("{}\n", encoding="utf-8")
            silver.write_text("{}\n", encoding="utf-8")
            vocab.write_text(
                json.dumps(KOKORO_VOCAB, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            expected.write_text("{}\n", encoding="utf-8")

            def digest(path):
                return hashlib.sha256(path.read_bytes()).hexdigest()

            lock.write_text(
                json.dumps(
                    {
                        "sourceID": "cmudict",
                        "upstreamURL": "https://github.com/cmusphinx/cmudict",
                        "commit": CMUDICT_COMMIT,
                        "dialect": "en-US",
                        "dictionary": {
                            "path": str(cmudict),
                            "sha256": f"sha256:{digest(cmudict)}",
                        },
                        "license": {
                            "path": str(license_path),
                            "sha256": f"sha256:{digest(license_path)}",
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
                    "check",
                    "--lock",
                    str(lock),
                    "--gold",
                    str(gold),
                    "--silver",
                    str(silver),
                    "--vocab",
                    str(vocab),
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
            cmudict = root / "cmudict.dict"
            license_path = root / "LICENSE"
            gold = root / "gold.json"
            silver = root / "silver.json"
            vocab = root / "vocab.json"
            lock = root / "lock.json"
            output = root / "pack.json"

            cmudict.write_text("APPLE  AE1 P AH0 L\n", encoding="utf-8")
            license_path.write_text("fixture license\n", encoding="utf-8")
            gold.write_text("{}\n", encoding="utf-8")
            silver.write_text("{}\n", encoding="utf-8")
            vocab.write_text(
                json.dumps(KOKORO_VOCAB, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )

            def digest(path):
                return hashlib.sha256(path.read_bytes()).hexdigest()

            lock.write_text(
                json.dumps(
                    {
                        "sourceID": "cmudict",
                        "upstreamURL": "https://github.com/cmusphinx/cmudict",
                        "commit": CMUDICT_COMMIT,
                        "dialect": "en-US",
                        "dictionary": {
                            "path": str(cmudict),
                            "sha256": f"sha256:{digest(cmudict)}",
                        },
                        "license": {
                            "path": str(license_path),
                            "sha256": f"sha256:{digest(license_path)}",
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

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertEqual(0o644, output.stat().st_mode & 0o777)


if __name__ == "__main__":
    unittest.main()
