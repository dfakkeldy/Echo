import unittest

from doc_automation.changes import CategorizedChanges
from doc_automation.render_testflight import (
    render,
    PLACEHOLDER,
    DEFAULT_MAX_CHARS,
    EMPTY_MESSAGE,
)

TEMPLATE = f"Intro line.\n\n{PLACEHOLDER}\n\nOutro line."


class RenderTests(unittest.TestCase):
    def test_fills_placeholder_with_grouped_bullets(self):
        changes = CategorizedChanges(new=["Pinch-to-zoom"], fixed=["Seek drift"], improved=["Faster load"])
        out = render(changes, TEMPLATE)
        self.assertIn("Intro line.", out)
        self.assertIn("Outro line.", out)
        self.assertIn("New", out)
        self.assertIn("• Pinch-to-zoom", out)
        self.assertIn("Fixed", out)
        self.assertIn("• Seek drift", out)
        self.assertIn("Improved", out)
        self.assertIn("• Faster load", out)
        self.assertNotIn(PLACEHOLDER, out)

    def test_omits_empty_groups(self):
        out = render(CategorizedChanges(new=["Only a feature"]), TEMPLATE)
        self.assertIn("New", out)
        self.assertNotIn("Fixed", out)
        self.assertNotIn("Improved", out)

    def test_empty_changes_uses_empty_message(self):
        out = render(CategorizedChanges(), TEMPLATE)
        self.assertIn(EMPTY_MESSAGE, out)

    def test_respects_char_cap_with_truncation_summary(self):
        many = CategorizedChanges(new=[f"Feature number {i} with some descriptive text" for i in range(200)])
        out = render(many, TEMPLATE, max_chars=500)
        self.assertLessEqual(len(out), 500)
        self.assertIn("more change", out)

    def test_under_cap_has_no_truncation_summary(self):
        out = render(CategorizedChanges(new=["Small"]), TEMPLATE, max_chars=DEFAULT_MAX_CHARS)
        self.assertNotIn("more change", out)


if __name__ == "__main__":
    unittest.main()
