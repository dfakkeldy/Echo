import datetime as dt
import unittest

from doc_automation.curate_devlog import (
    CurationResult,
    build_curation_prompt,
    extract_response_text,
    render_pr_body,
    render_review_checklist,
)
from doc_automation.devlog import DevlogDigest, DevlogItem


class CurationPromptTests(unittest.TestCase):
    def test_build_prompt_keeps_social_drafts_grounded_in_factual_digest(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=2,
            features=[DevlogItem("Add import review", "abc1234")],
            fixes=[DevlogItem("Keep timer state after pause", "def5678")],
        )

        prompt = build_curation_prompt(
            digest=digest,
            project_name="Turn Timer",
            repo_url="https://github.com/example/TurnTimer",
            extra_guidance="The project is being rebranded from Visual Timer.",
        )

        self.assertIn("Use only the factual digest", prompt)
        self.assertIn("Do not invent", prompt)
        self.assertIn("Devlog draft", prompt)
        self.assertIn("Short social post", prompt)
        self.assertIn("Reddit-safe", prompt)
        self.assertIn("Add import review", prompt)
        self.assertIn("The project is being rebranded from Visual Timer.", prompt)

    def test_extract_response_text_reads_responses_api_output_content(self):
        payload = {
            "output": [
                {
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": "First paragraph."},
                        {"type": "output_text", "text": "Second paragraph."},
                    ],
                }
            ]
        }

        self.assertEqual(extract_response_text(payload), "First paragraph.\n\nSecond paragraph.")


class ReviewChecklistTests(unittest.TestCase):
    def test_render_review_checklist_includes_human_merge_checks_and_project_notes(self):
        checklist = render_review_checklist(
            project_name="Routey",
            markdown_path="docs/guides/devlog.md",
            html_path="devlog.html",
            extra_checklist="No real route data, street names, employer names, civic numbers, or carrier-specific jargon.",
        )

        self.assertIn("- [ ] I read the generated digest and AI-assisted draft before merging.", checklist)
        self.assertIn("- [ ] Every public claim is supported by linked commits or existing docs.", checklist)
        self.assertIn("docs/guides/devlog.md", checklist)
        self.assertIn("devlog.html", checklist)
        self.assertIn("No real route data", checklist)

    def test_render_pr_body_includes_checklist_curation_and_factual_digest(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=1,
            features=[DevlogItem("Add launch checklist", "abc1234")],
        )

        body = render_pr_body(
            digest=digest,
            project_name="MacroMark",
            repo_url="https://github.com/example/MacroMark",
            curation=CurationResult(status="available", text="## Devlog draft\nA concise draft."),
            markdown_path="docs/guides/devlog.md",
            html_path="docs/devlog.html",
            extra_checklist="",
        )

        self.assertIn("Automated weekly devlog digest for Jun 22-28, 2026.", body)
        self.assertIn("## Review checklist", body)
        self.assertIn("## AI-assisted draft", body)
        self.assertIn("A concise draft.", body)
        self.assertIn("## Factual source digest", body)
        self.assertIn("Add launch checklist ([abc1234](https://github.com/example/MacroMark/commit/abc1234))", body)

    def test_render_pr_body_compacts_noisy_source_groups(self):
        digest = DevlogDigest(
            title="Weekly build digest",
            start=dt.date(2026, 6, 22),
            end=dt.date(2026, 6, 29),
            commit_count=3,
            features=[
                DevlogItem("First", "1111111"),
                DevlogItem("Second", "2222222"),
                DevlogItem("Third", "3333333"),
            ],
        )

        body = render_pr_body(
            digest=digest,
            project_name="Echo",
            repo_url="https://github.com/example/Echo",
            curation=CurationResult(status="skipped", text="No key."),
            markdown_path="docs/guides/devlog.md",
            html_path="docs/devlog.html",
            extra_checklist="",
            max_items_per_group=2,
        )

        self.assertIn("- First", body)
        self.assertIn("- Second", body)
        self.assertNotIn("- Third", body)
        self.assertIn("- ...and 1 more shipped item.", body)


if __name__ == "__main__":
    unittest.main()
