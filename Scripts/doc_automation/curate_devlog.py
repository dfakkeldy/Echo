"""Create a review-ready PR body for weekly build-in-public devlog updates."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from doc_automation.devlog import (
    DEFAULT_MAX_ITEMS_PER_GROUP,
    DEFAULT_REPO_URL,
    DEFAULT_TIMEZONE,
    DISPLAY_GROUPS,
    DevlogDigest,
    DevlogItem,
    build_digest,
    get_commits,
    weekly_window,
)

DEFAULT_MODEL = "gpt-5.4-mini"
RESPONSES_URL = "https://api.openai.com/v1/responses"


@dataclass(frozen=True)
class CurationResult:
    status: str
    text: str


def build_curation_prompt(
    digest: DevlogDigest,
    project_name: str,
    repo_url: str,
    extra_guidance: str = "",
    max_items_per_group: int = DEFAULT_MAX_ITEMS_PER_GROUP,
) -> str:
    guidance = extra_guidance.strip() or "No additional project-specific guidance."
    return "\n".join(
        [
            f"You are drafting build-in-public copy for {project_name}.",
            "",
            "Use only the factual digest below. Do not invent release dates, launch status, user counts,",
            "download numbers, revenue, platform accounts, testimonials, or feature claims not supported by the digest.",
            "If the week is mostly maintenance, say that plainly and keep the tone practical.",
            "",
            "Write Markdown with exactly these sections:",
            "## Devlog draft",
            "Two short paragraphs for the project devlog, written in first person singular.",
            "## Social drafts",
            "### Short social post",
            "One post suitable for X, Bluesky, Mastodon, or Threads. Keep it under 280 characters.",
            "### Longer social post",
            "One warmer post suitable for Bluesky, Mastodon, Threads, or LinkedIn. Keep it under 800 characters.",
            "## Reddit-safe angle",
            "One non-promotional discussion angle. If there is no genuinely useful angle, say to skip Reddit this week.",
            "## Human review notes",
            "Three bullets naming claims, tone, or privacy details the developer should verify before posting.",
            "",
            "Project guidance:",
            guidance,
            "",
            f"Repository: {repo_url}",
            f"Week: {_format_range(digest.start, digest.end)}",
            "",
            "Factual digest:",
            render_source_digest(digest, repo_url, max_items_per_group),
        ]
    )


def extract_response_text(payload: dict) -> str:
    direct_text = payload.get("output_text")
    if isinstance(direct_text, str) and direct_text.strip():
        return direct_text.strip()

    parts: list[str] = []
    for output in payload.get("output", []):
        if not isinstance(output, dict):
            continue
        for content in output.get("content", []):
            if not isinstance(content, dict):
                continue
            text = content.get("text")
            if content.get("type") == "output_text" and isinstance(text, str) and text.strip():
                parts.append(text.strip())
    return "\n\n".join(parts)


def request_curation(prompt: str, api_key: str | None, model: str, timeout: float = 45.0) -> CurationResult:
    if not api_key:
        return CurationResult(
            status="skipped",
            text="OPENAI_API_KEY is not configured, so no AI-assisted draft was generated.",
        )

    payload = {"model": model, "input": prompt}
    request = urllib.request.Request(
        RESPONSES_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        return CurationResult(status="failed", text=f"AI curation request failed: {error}")

    text = extract_response_text(body)
    if not text:
        return CurationResult(status="failed", text="AI curation returned no usable text.")
    return CurationResult(status="available", text=text)


def render_review_checklist(
    project_name: str,
    markdown_path: str,
    html_path: str,
    extra_checklist: str = "",
) -> str:
    lines = [
        "## Review checklist",
        f"- [ ] I read the generated digest and AI-assisted draft before merging.",
        "- [ ] Every public claim is supported by linked commits or existing docs.",
        "- [ ] No revenue, download count, user count, launch date, or platform-account claim was invented.",
        "- [ ] The tone sounds like me and is appropriate for a public build-in-public update.",
        f"- [ ] `{markdown_path}` and `{html_path}` render correctly after merge.",
        "- [ ] I am intentionally choosing what to post manually; nothing here auto-posts to social media.",
    ]
    note = extra_checklist.strip()
    if note:
        lines.append(f"- [ ] {note}")
    return "\n".join(lines)


def render_pr_body(
    digest: DevlogDigest,
    project_name: str,
    repo_url: str,
    curation: CurationResult,
    markdown_path: str,
    html_path: str,
    extra_checklist: str = "",
    max_items_per_group: int = DEFAULT_MAX_ITEMS_PER_GROUP,
) -> str:
    lines = [
        f"Automated weekly devlog digest for {_format_range(digest.start, digest.end)}.",
        "",
        render_review_checklist(project_name, markdown_path, html_path, extra_checklist),
        "",
        "## AI-assisted draft",
        f"_Status: {curation.status}._",
        "",
        curation.text.strip(),
        "",
        "## Factual source digest",
        render_source_digest(digest, repo_url, max_items_per_group),
    ]
    return "\n".join(lines).rstrip() + "\n"


def render_source_digest(
    digest: DevlogDigest,
    repo_url: str,
    max_items_per_group: int = DEFAULT_MAX_ITEMS_PER_GROUP,
) -> str:
    lines = [
        f"Generated from {digest.commit_count} {_commit_word(digest.commit_count)} in {_format_range(digest.start, digest.end)}.",
    ]
    for attr, heading, omitted_label in DISPLAY_GROUPS:
        items = getattr(digest, attr)
        if not items:
            continue
        visible_items, omitted_count = _compact_items(items, max_items_per_group)
        lines.extend(["", f"### {heading}"])
        lines.extend(f"- {_markdown_item(item, repo_url)}" for item in visible_items)
        if omitted_count:
            lines.append(f"- ...and {omitted_count} more {omitted_label} {_item_word(omitted_count)}.")
    return "\n".join(lines)


def _markdown_item(item: DevlogItem, repo_url: str) -> str:
    if not item.sha:
        return item.text
    return f"{item.text} ([{item.sha}]({repo_url}/commit/{item.sha}))"


def _format_range(start: dt.date, end: dt.date) -> str:
    display_end = end - dt.timedelta(days=1)
    if start.year == display_end.year and start.month == display_end.month:
        return f"{start:%b} {start.day}-{display_end.day}, {start.year}"
    if start.year == display_end.year:
        return f"{start:%b} {start.day}-{display_end:%b} {display_end.day}, {start.year}"
    return f"{start:%b} {start.day}, {start.year}-{display_end:%b} {display_end.day}, {display_end.year}"


def _commit_word(count: int) -> str:
    return "commit" if count == 1 else "commits"


def _item_word(count: int) -> str:
    return "item" if count == 1 else "items"


def _compact_items(items: list[DevlogItem], max_items: int) -> tuple[list[DevlogItem], int]:
    if max_items < 1 or len(items) <= max_items:
        return items, 0
    return items[:max_items], len(items) - max_items


def _parse_datetime(value: str, zone: ZoneInfo) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=zone)
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate a review-ready PR body for weekly devlog updates.")
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--markdown", default="docs/guides/devlog.md")
    parser.add_argument("--html", default="docs/devlog.html")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL)
    parser.add_argument("--timezone", default=DEFAULT_TIMEZONE)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--since", help="Start datetime, default: previous Monday at 00:00 America/Halifax")
    parser.add_argument("--until", help="Exclusive end datetime, default: current Monday at 00:00 America/Halifax")
    parser.add_argument("--model", default=os.environ.get("OPENAI_MODEL", DEFAULT_MODEL))
    parser.add_argument("--extra-guidance", default="")
    parser.add_argument("--extra-checklist", default="")
    parser.add_argument("--out", default="-", help="Output path, or '-' for stdout.")
    args = parser.parse_args(argv)

    zone = ZoneInfo(args.timezone)
    if args.since or args.until:
        if not (args.since and args.until):
            parser.error("--since and --until must be provided together")
        start = _parse_datetime(args.since, zone)
        end = _parse_datetime(args.until, zone)
    else:
        start, end = weekly_window(timezone=args.timezone)

    commits = get_commits(start, end, args.head)
    digest = build_digest(commits, title="Weekly build digest", start=start.date(), end=end.date())
    if digest.is_empty():
        print(f"devlog-pr-body: no eligible commits between {start.isoformat()} and {end.isoformat()}", file=sys.stderr)
        return 0

    prompt = build_curation_prompt(digest, args.project_name, args.repo_url, args.extra_guidance)
    curation = request_curation(prompt, os.environ.get("OPENAI_API_KEY"), args.model)
    body = render_pr_body(
        digest=digest,
        project_name=args.project_name,
        repo_url=args.repo_url,
        curation=curation,
        markdown_path=args.markdown,
        html_path=args.html,
        extra_checklist=args.extra_checklist,
    )

    if args.out == "-":
        print(body, end="")
    else:
        Path(args.out).write_text(body)
        print(f"devlog-pr-body: wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
