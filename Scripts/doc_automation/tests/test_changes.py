import unittest

from doc_automation.changes import (
    RawCommit,
    CategorizedChanges,
    clean_description,
    find_trailers,
    categorize,
)


class CleanDescriptionTests(unittest.TestCase):
    def test_capitalizes_and_strips_trailing_period(self):
        self.assertEqual(clean_description("pinch-to-zoom."), "Pinch-to-zoom")

    def test_leaves_already_capitalized(self):
        self.assertEqual(clean_description("Pinch-to-zoom"), "Pinch-to-zoom")

    def test_empty_stays_empty(self):
        self.assertEqual(clean_description("   "), "")


class FindTrailersTests(unittest.TestCase):
    def test_tester_note_extracted(self):
        note, skip = find_trailers("body text\nTester-note: Re-import your library to test")
        self.assertEqual(note, "Re-import your library to test")
        self.assertFalse(skip)

    def test_skip_changelog_bare(self):
        note, skip = find_trailers("body\nskip-changelog")
        self.assertIsNone(note)
        self.assertTrue(skip)

    def test_skip_changelog_explicit_false(self):
        _, skip = find_trailers("body\nSkip-Changelog: false")
        self.assertFalse(skip)

    def test_no_trailers(self):
        self.assertEqual(find_trailers("just a body"), (None, False))


class CategorizeTests(unittest.TestCase):
    def test_includes_feat_fix_perf_and_groups_them(self):
        result = categorize([
            RawCommit("feat(reader): pinch-to-zoom"),
            RawCommit("fix(player): correct seek drift"),
            RawCommit("perf(db): faster library load"),
        ])
        self.assertEqual(result.new, ["Pinch-to-zoom"])
        self.assertEqual(result.fixed, ["Correct seek drift"])
        self.assertEqual(result.improved, ["Faster library load"])

    def test_excludes_non_user_facing_types(self):
        result = categorize([
            RawCommit("chore: bump deps"),
            RawCommit("ci: tweak workflow"),
            RawCommit("docs: update readme"),
            RawCommit("refactor: rename service"),
            RawCommit("test: add coverage"),
            RawCommit("build: adjust settings"),
            RawCommit("style: format"),
        ])
        self.assertTrue(result.is_empty())

    def test_non_conventional_subject_excluded(self):
        self.assertTrue(categorize([RawCommit("random commit message")]).is_empty())

    def test_skip_changelog_drops_included_type(self):
        result = categorize([RawCommit("feat: secret thing", "body\nskip-changelog")])
        self.assertTrue(result.is_empty())

    def test_tester_note_forces_bullet_with_its_text(self):
        result = categorize([
            RawCommit("chore: internal", "body\nTester-note: Please test offline playback"),
        ])
        self.assertEqual(result.new, ["Please test offline playback"])

    def test_tester_note_grouped_by_type_when_recognized(self):
        result = categorize([
            RawCommit("fix(sync): edge case", "Tester-note: Verify sync after airplane mode"),
        ])
        self.assertEqual(result.fixed, ["Verify sync after airplane mode"])
        self.assertEqual(result.new, [])

    def test_total_and_is_empty(self):
        empty = CategorizedChanges()
        self.assertTrue(empty.is_empty())
        self.assertEqual(empty.total(), 0)
        self.assertEqual(categorize([RawCommit("feat: a"), RawCommit("fix: b")]).total(), 2)


if __name__ == "__main__":
    unittest.main()
