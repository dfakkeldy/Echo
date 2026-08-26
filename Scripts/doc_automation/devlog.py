"""Generate deterministic weekly devlog digest blocks from git history.

The handwritten devlog remains the narrative source of truth. This module owns
only the replaceable weekly digest block that can be refreshed unattended.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo

from doc_automation.changes import CONVENTIONAL_RE, RawCommit, clean_description, find_trailers

AUTO_START = "<!-- AUTO-DEVLOG:START -->"
AUTO_END = "<!-- AUTO-DEVLOG:END -->"
DEFAULT_REPO_URL = "https://github.com/dfakkeldy/Echo"
DEFAULT_TIMEZONE = "America/Halifax"
DEFAULT_MAX_ITEMS_PER_GROUP = 8
UNIT_SEP = "\x1f"
RECORD_SEP = "\x1e"

USER_FACING_TYPES = {
    "feat": "features",
    "fix": "fixes",
    "perf": "improvements",
}

HOUSEKEEPING_TYPES = {
    "build",
    "chore",
    "ci",
    "docs",
    "refactor",
    "style",
    "test",
}

DISPLAY_GROUPS = [
    ("features", "Shipped", "shipped"),
    ("fixes", "Fixed", "fixed"),
    ("improvements", "Improved", "improved"),
    ("housekeeping", "Build, docs, and housekeeping", "housekeeping"),
]


@dataclass(frozen=True)
class DevlogItem:
    text: str
    sha: str = ""


@dataclass
class DevlogDigest:
    title: str
    start: dt.date
    end: dt.date
    commit_count: int
    features: list[DevlogItem] = field(default_factory=list)
    fixes: list[DevlogItem] = field(default_factory=list)
    improvements: list[DevlogItem] = field(default_factory=list)
    housekeeping: list[DevlogItem] = field(default_factory=list)

    def is_empty(self) -> bool:
        return not (self.features or self.fixes or self.improvements or self.housekeeping)


def weekly_window(now: dt.datetime | None = None, timezone: str = DEFAULT_TIMEZONE) -> tuple[dt.datetime, dt.datetime]:
    zone = ZoneInfo(timezone) if now is None or now.tzinfo is None else now.tzinfo
    local_now = (now or dt.datetime.now(zone)).astimezone(zone)
    current_monday = local_now.date() - dt.timedelta(days=local_now.weekday())
    end = dt.datetime.combine(current_monday, dt.time.min, tzinfo=zone)
    start = end - dt.timedelta(days=7)
    return start, end


def build_digest(
    commits: list[RawCommit],
    title: str,
    start: dt.date,
    end: dt.date,
) -> DevlogDigest:
    digest = DevlogDigest(title=title, start=start, end=end, commit_count=0)
    for commit in commits:
        tester_note, skip = find_trailers(commit.body)
        if skip:
            continue

        subject = commit.subject.strip()
        match = CONVENTIONAL_RE.match(subject)
        if not match:
            continue

        commit_type = match.group("type")
        if tester_note:
            text = tester_note
            group = USER_FACING_TYPES.get(commit_type, "housekeeping")
        elif commit_type in USER_FACING_TYPES:
            text = clean_description(match.group("desc"))
            group = USER_FACING_TYPES[commit_type]
        elif commit_type in HOUSEKEEPING_TYPES:
            text = clean_description(match.group("desc"))
            group = "housekeeping"
        else:
            continue

        if text:
            getattr(digest, group).append(DevlogItem(text=text, sha=commit.sha))
            digest.commit_count += 1
    return digest


def render_markdown_update(
    digest: DevlogDigest,
    repo_url: str = DEFAULT_REPO_URL,
    max_items_per_group: int = DEFAULT_MAX_ITEMS_PER_GROUP,
) -> str:
    lines = [
        AUTO_START,
        f"## Automated update - {_format_range(digest.start, digest.end)}",
        "",
        f"*Generated from {digest.commit_count} {_commit_word(digest.commit_count)} merged during the week.*",
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
    lines.extend(["", AUTO_END])
    return "\n".join(lines)


def render_html_update(
    digest: DevlogDigest,
    repo_url: str = DEFAULT_REPO_URL,
    max_items_per_group: int = DEFAULT_MAX_ITEMS_PER_GROUP,
) -> str:
    lines = [
        "            " + AUTO_START,
        '            <article class="week-entry automated-devlog">',
        f"                <p class=\"week-meta\">Automated · {_format_range(digest.start, digest.end)} · {digest.commit_count} {_commit_word(digest.commit_count)}</p>",
        f"                <h2>{html.escape(digest.title)}</h2>",
    ]
    for attr, heading, omitted_label in DISPLAY_GROUPS:
        items = getattr(digest, attr)
        if not items:
            continue
        visible_items, omitted_count = _compact_items(items, max_items_per_group)
        lines.append(f"                <h3>{html.escape(heading)}</h3>")
        lines.append("                <ul>")
        lines.extend(f"                    <li>{_html_item(item, repo_url)}</li>" for item in visible_items)
        if omitted_count:
            omitted_text = f"...and {omitted_count} more {omitted_label} {_item_word(omitted_count)}."
            lines.append(f"                    <li><em>{html.escape(omitted_text)}</em></li>")
        lines.append("                </ul>")
    lines.extend([
        "            </article>",
        "            " + AUTO_END,
    ])
    return "\n".join(lines)


def replace_markdown_block(source: str, block: str) -> str:
    existing = _existing_block_range(source)
    if existing:
        start, end = existing
        return source[:start] + block + source[end:]

    rule = "\n---\n\n"
    rule_index = source.find(rule)
    if rule_index != -1:
        insertion = rule_index + len(rule)
        return source[:insertion] + block + "\n\n" + source[insertion:]

    return block + "\n\n" + source


def replace_html_block(source: str, block: str) -> str:
    existing = _existing_block_range(source)
    if existing:
        start, end = existing
        return source[:start] + block + source[end:]

    timeline = '<div class="devlog-timeline">'
    timeline_index = source.find(timeline)
    if timeline_index == -1:
        raise ValueError("docs/devlog.html is missing the devlog timeline container")

    newline_index = source.find("\n", timeline_index)
    if newline_index == -1:
        raise ValueError("docs/devlog.html has an unterminated devlog timeline container")

    insertion = newline_index + 1
    return source[:insertion] + block + "\n\n" + source[insertion:]


def get_commits(start: dt.datetime, end: dt.datetime, head: str = "HEAD") -> list[RawCommit]:
    fmt = f"%H{UNIT_SEP}%s{UNIT_SEP}%b{RECORD_SEP}"
    result = subprocess.run(
        [
            "git",
            "log",
            "--no-merges",
            f"--format={fmt}",
            f"--since={start.isoformat()}",
            f"--before={end.isoformat()}",
            head,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    commits: list[RawCommit] = []
    for record in result.stdout.split(RECORD_SEP):
        record = record.strip("\n")
        if not record.strip():
            continue
        sha, _, rest = record.partition(UNIT_SEP)
        subject, _, body = rest.partition(UNIT_SEP)
        commits.append(RawCommit(subject=subject.strip(), body=body, sha=sha[:7]))
    return commits


def update_docs(markdown_path: Path, html_path: Path, digest: DevlogDigest, repo_url: str) -> bool:
    markdown_block = render_markdown_update(digest, repo_url)
    html_block = render_html_update(digest, repo_url)

    markdown_source = markdown_path.read_text()
    html_source = html_path.read_text()
    next_markdown = replace_markdown_block(markdown_source, markdown_block)
    next_html = replace_html_block(html_source, html_block)

    changed = False
    if next_markdown != markdown_source:
        markdown_path.write_text(next_markdown)
        changed = True
    if next_html != html_source:
        html_path.write_text(next_html)
        changed = True
    return changed


def _existing_block_range(source: str) -> tuple[int, int] | None:
    start = source.find(AUTO_START)
    end = source.find(AUTO_END)
    if start == -1 and end == -1:
        return None
    if start == -1 or end == -1 or end < start:
        raise ValueError("auto devlog markers are unbalanced")
    line_start = source.rfind("\n", 0, start) + 1
    if source[line_start:start].strip() == "":
        start = line_start
    return start, end + len(AUTO_END)


def _markdown_item(item: DevlogItem, repo_url: str) -> str:
    if not item.sha:
        return item.text
    return f"{item.text} ([{item.sha}]({repo_url}/commit/{item.sha}))"


def _html_item(item: DevlogItem, repo_url: str) -> str:
    text = html.escape(item.text)
    if not item.sha:
        return text
    sha = html.escape(item.sha)
    url = html.escape(f"{repo_url}/commit/{item.sha}", quote=True)
    return f'{text} <a href="{url}" target="_blank" rel="noopener noreferrer">{sha}</a>'


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
    if isinstance(parsed, dt.datetime):
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=zone)
        return parsed
    raise ValueError(f"invalid datetime: {value}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Update Echo's generated weekly devlog digest.")
    parser.add_argument("--markdown", default="docs/guides/devlog.md")
    parser.add_argument("--html", default="docs/devlog.html")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL)
    parser.add_argument("--timezone", default=DEFAULT_TIMEZONE)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--since", help="Start datetime, default: previous Monday at 00:00 America/Halifax")
    parser.add_argument("--until", help="Exclusive end datetime, default: current Monday at 00:00 America/Halifax")
    parser.add_argument("--title", default="Weekly build digest")
    parser.add_argument("--dry-run", action="store_true")
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
    digest = build_digest(commits, title=args.title, start=start.date(), end=end.date())
    if digest.is_empty():
        print(f"devlog: no eligible commits between {start.isoformat()} and {end.isoformat()}")
        return 0

    if args.dry_run:
        print(render_markdown_update(digest, args.repo_url))
        return 0

    changed = update_docs(Path(args.markdown), Path(args.html), digest, args.repo_url)
    if changed:
        print(f"devlog: updated {args.markdown} and {args.html} with {digest.commit_count} commits")
    else:
        print("devlog: generated block already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
