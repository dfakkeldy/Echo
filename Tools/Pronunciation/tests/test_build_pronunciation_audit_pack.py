import unittest

from Tools.Pronunciation.build_pronunciation_audit_pack import build_audit_pack


KOKORO_VOCAB = {
    "vocab": {
        "ɑ": 1, "æ": 2, "ə": 3, "ɔ": 4, "ɪ": 5, "ɛ": 6, "ɚ": 7,
        "ɹ": 8, "b": 9, "d": 10, "k": 11, "l": 12, "m": 13,
        "n": 14, "p": 15, "s": 16, "t": 17, "ˈ": 18,
    }
}


class PronunciationAuditPackGeneratorTests(unittest.TestCase):
    def build(self, **overrides):
        arguments = {
            "cmu_lines": ["RECORD  R EH1 K ER0 D", "APPLE  AE1 P AH0 L"],
            "gold": {"record": "ɹɪkˈɔɹd"},
            "silver": {},
            "kokoro_vocab": KOKORO_VOCAB,
            "generation_timestamp": "2026-08-03T12:00:00Z",
        }
        arguments.update(overrides)
        return build_audit_pack(**arguments)

    def test_overlap_is_advisory_only(self):
        pack = self.build()

        candidate = pack["entries"]["record"]["candidates"][0]
        self.assertFalse(candidate["automaticEligible"])
        self.assertEqual("uncertain", candidate["authority"])
        self.assertEqual("shadow", candidate["validation"])
        self.assertIn("auditPackVersion", pack)

    def test_retains_only_normalized_overlaps_with_different_ipa_sets(self):
        result = self.build(
            cmu_lines=[
                "RECORD  R EH1 K ER0 D",
                "APPLE  AE1 P AH0 L",
                "MISSING  M IH1 S IH0 NG",
            ],
            gold={"record": "ɹɪkˈɔɹd", "apple": "ˈæpəl", "other": "ˈʌðɚ"},
            silver={"RECORD(2)": "ɹˈɛkɚd"},
        )

        self.assertEqual(["record"], list(result["entries"]))

    def test_identical_source_candidates_collapse_deterministically(self):
        result = self.build(gold={"record": {"DEFAULT": "ɹɪkˈɔɹd", "VERB": "ɹɪkˈɔɹd"}})

        candidates = result["entries"]["record"]["candidates"]
        self.assertEqual(2, len(candidates))
        self.assertEqual(["cmudict", "echo-us-gold"], [item["sourceID"] for item in candidates])

    def test_incompatible_ipa_is_rejected(self):
        result = self.build(gold={"record": "ɹ❓kˈɔɹd"})

        self.assertEqual({}, result["entries"])
        self.assertEqual(1, result["report"]["incompatible"])

    def test_metadata_is_mandatory(self):
        with self.assertRaisesRegex(ValueError, "licenses"):
            self.build(licenses=[])
        with self.assertRaisesRegex(ValueError, "sources"):
            self.build(sources=[])

    def test_output_ordering_is_stable_and_content_rotates_version(self):
        first = self.build(cmu_lines=["ZEBRA  Z IY1 B R AH0", "RECORD  R EH1 K ER0 D"])
        second = self.build(cmu_lines=["RECORD  R EH1 K ER0 D", "ZEBRA  Z IY1 B R AH0"])
        changed = self.build(gold={"record": "ɹˈɛkɚd"})

        self.assertEqual(first, second)
        self.assertNotEqual(first["auditPackVersion"], changed["auditPackVersion"])

    def test_all_candidates_are_ineligible_for_automatic_use(self):
        result = self.build()
        self.assertTrue(
            all(
                not candidate["automaticEligible"]
                for entry in result["entries"].values()
                for candidate in entry["candidates"]
            )
        )
