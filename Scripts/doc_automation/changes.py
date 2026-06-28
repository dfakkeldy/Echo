"""Pure commit parsing & categorization — the reusable change-extractor spine.

No I/O, no git, no LLM. Given Conventional-Commit subjects/bodies, produce a
grouped, filtered, tester-facing change list.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# type(scope)!: description  — scope and the breaking-change "!" are optional.
CONVENTIONAL_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<desc>.+)$"
)

# Conventional-Commit type -> CategorizedChanges attribute name.
INCLUDED_TYPES = {"feat": "new", "fix": "fixed", "perf": "improved"}


@dataclass(frozen=True)
class RawCommit:
    subject: str
    body: str = ""
    sha: str = ""


@dataclass
class CategorizedChanges:
    new: list[str] = field(default_factory=list)       # feat
    fixed: list[str] = field(default_factory=list)      # fix
    improved: list[str] = field(default_factory=list)   # perf

    def is_empty(self) -> bool:
        return not (self.new or self.fixed or self.improved)

    def total(self) -> int:
        return len(self.new) + len(self.fixed) + len(self.improved)


def clean_description(desc: str) -> str:
    desc = desc.strip().rstrip(".").strip()
    if not desc:
        return ""
    return desc[:1].upper() + desc[1:]


def find_trailers(body: str) -> tuple[str | None, bool]:
    """Parse commit-body trailers. Returns (tester_note, skip)."""
    tester_note: str | None = None
    skip = False
    for line in body.splitlines():
        stripped = line.strip()
        lower = stripped.lower()
        if lower.startswith("tester-note:"):
            tester_note = stripped.split(":", 1)[1].strip()
        elif lower == "skip-changelog" or lower.startswith("skip-changelog:"):
            value = stripped.split(":", 1)[1].strip().lower() if ":" in stripped else "true"
            skip = value not in ("false", "no", "0")
    return tester_note, skip


def categorize(commits: list[RawCommit]) -> CategorizedChanges:
    result = CategorizedChanges()
    for commit in commits:
        tester_note, skip = find_trailers(commit.body)
        if skip:
            continue
        match = CONVENTIONAL_RE.match(commit.subject.strip())
        ctype = match.group("type") if match else None
        if tester_note is not None:
            bullet = tester_note
            group = INCLUDED_TYPES.get(ctype, "new")
        else:
            if ctype not in INCLUDED_TYPES:
                continue
            group = INCLUDED_TYPES[ctype]
            bullet = clean_description(match.group("desc"))
        if bullet:
            getattr(result, group).append(bullet)
    return result
