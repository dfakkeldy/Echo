import datetime as dt
import unittest

from doc_automation.changes import RawCommit
from doc_automation.devlog import (
    AUTO_END,
    AUTO_START,
    DevlogItem,
    DevlogDigest,
    build_digest,
    render_html_update,
    render_markdown_update,
    replace_html_block,
    replace_markdown_block,
    weekly_window,
)


class WeeklyWindowTests(unittest.TestCase):
    def test_monday_one_am_halifax_covers_previous_calendar_week(self):
        now = dt.datetime(2026, 6, 29, 1, 0, tzinfo=dt.timezone(dt.timedelta(hours=-3)))

        start, end = weekly_window(now)

        self.assertEqual(start.isoformat(), "2026-06-22T00:00:00-03:00")
        self.assertEqual(end.isoformat(), "2026-06-29T00:00:00-03:00")


class DevlogDigestTests(unittest.TestCase):
    def test_build_digest_groups_user_facing_and_housekeeping_commits(self):
        digest = build_digest(
            [
                RawCommit(subject="feat(reader): add focus cards", sha="abc1234"),
                RawCommit(subject="fix(player): keep position after calls", sha="def5678"),
                RawCommit(subject="perf(sync): reduce launch work", sha="999aaaa"),
                RawCommit(subject="docs: explain beta flow", sha="555dddd"),
                RawCommit(subject="test: add coverage", sha="000skip"),
            ],
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
        )

        self.assertEqual(digest.commit_count, 5)
        self.assertEqual(digest.features[0].text, "Add focus cards")
        self.assertEqual(digest.fixes[0].text, "Keep position after calls")
        self.assertEqual(digest.improvements[0].text, "Reduce launch work")
        self.assertEqual(digest.housekeeping[0].text, "Explain beta flow")
        self.assertEqual(digest.housekeeping[1].text, "Add coverage")

    def test_render_markdown_update_includes_commit_links_and_group_headings(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=2,
            features=[DevlogItem("Add focus cards", "abc1234")],
            fixes=[DevlogItem("Keep position", "def5678")],
        )

        output = render_markdown_update(digest, "https://github.com/example/Echo")

        self.assertIn(AUTO_START, output)
        self.assertIn("## Automated update - Jun 22-28, 2026", output)
        self.assertIn("### Shipped", output)
        self.assertIn("- Add focus cards ([abc1234](https://github.com/example/Echo/commit/abc1234))", output)
        self.assertIn("### Fixed", output)
        self.assertIn(AUTO_END, output)

    def test_render_markdown_update_compacts_large_groups(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=3,
            features=[
                DevlogItem("One", "1111111"),
                DevlogItem("Two", "2222222"),
                DevlogItem("Three", "3333333"),
            ],
        )

        output = render_markdown_update(digest, "https://github.com/example/Echo", max_items_per_group=2)

        self.assertIn("- One", output)
        self.assertIn("- Two", output)
        self.assertNotIn("- Three", output)
        self.assertIn("- ...and 1 more shipped item.", output)

    def test_render_html_update_escapes_text(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=1,
            features=[DevlogItem("A < b", "abc1234")],
        )

        output = render_html_update(digest, "https://github.com/example/Echo")

        self.assertIn("Automated · Jun 22-28, 2026 · 1 commit", output)
        self.assertIn("A &lt; b", output)
        self.assertIn('href="https://github.com/example/Echo/commit/abc1234"', output)


class ReplaceBlockTests(unittest.TestCase):
    def test_replace_markdown_block_inserts_after_intro_rule_when_missing(self):
        source = "# Title\n\nIntro.\n\n---\n\n## Now\n"
        block = f"{AUTO_START}\nGenerated\n{AUTO_END}"

        output = replace_markdown_block(source, block)

        self.assertEqual(output, "# Title\n\nIntro.\n\n---\n\n" + block + "\n\n## Now\n")

    def test_replace_markdown_block_replaces_existing_generated_block(self):
        source = f"# Title\n\n---\n\n{AUTO_START}\nOld\n{AUTO_END}\n\n## Now\n"
        block = f"{AUTO_START}\nNew\n{AUTO_END}"

        output = replace_markdown_block(source, block)

        self.assertIn("New", output)
        self.assertNotIn("Old", output)

    def test_replace_html_block_inserts_inside_devlog_timeline(self):
        source = '<div class="devlog-timeline">\n            <article>Old</article>\n'
        block = f"            {AUTO_START}\n            <article>Generated</article>\n            {AUTO_END}"

        output = replace_html_block(source, block)

        self.assertIn('<div class="devlog-timeline">\n' + block + "\n\n            <article>Old</article>", output)

    def test_replace_html_block_replaces_existing_indented_block_cleanly(self):
        source = (
            '<div class="devlog-timeline">\n'
            f"            {AUTO_START}\n"
            "            <article>Old</article>\n"
            f"            {AUTO_END}\n\n"
            "            <article>Manual</article>\n"
        )
        block = f"            {AUTO_START}\n            <article>Generated</article>\n            {AUTO_END}"

        output = replace_html_block(source, block)

        self.assertIn('\n            <!-- AUTO-DEVLOG:START -->\n', output)
        self.assertNotIn('\n                        <!-- AUTO-DEVLOG:START -->\n', output)
        self.assertNotIn("Old", output)


if __name__ == "__main__":
    unittest.main()
