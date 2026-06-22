"""Pure rendering of CategorizedChanges into a TestFlight 'What to Test' string."""
from __future__ import annotations

from doc_automation.changes import CategorizedChanges

PLACEHOLDER = "{{CHANGES}}"
DEFAULT_MAX_CHARS = 4000
EMPTY_MESSAGE = "No user-facing changes since the last weekly build."
BULLET = "•"  # •

# (attribute name, display heading) in display order.
GROUPS = [("new", "New"), ("fixed", "Fixed"), ("improved", "Improved")]


def _format_block(changes: CategorizedChanges) -> str:
    if changes.is_empty():
        return EMPTY_MESSAGE
    blocks: list[str] = []
    for attr, heading in GROUPS:
        bullets = getattr(changes, attr)
        if bullets:
            lines = [heading] + [f"{BULLET} {b}" for b in bullets]
            blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _flatten(changes: CategorizedChanges) -> list[tuple[str, str]]:
    return [(attr, b) for attr, _ in GROUPS for b in getattr(changes, attr)]


def _subset(flat: list[tuple[str, str]], keep: int) -> CategorizedChanges:
    subset = CategorizedChanges()
    for attr, bullet in flat[:keep]:
        getattr(subset, attr).append(bullet)
    return subset


def render(changes: CategorizedChanges, template: str, max_chars: int = DEFAULT_MAX_CHARS) -> str:
    out = template.replace(PLACEHOLDER, _format_block(changes))
    if len(out) <= max_chars:
        return out

    flat = _flatten(changes)
    for keep in range(len(flat) - 1, -1, -1):
        block = _format_block(_subset(flat, keep))
        dropped = len(flat) - keep
        if dropped:
            suffix = "change" if dropped == 1 else "changes"
            block += f"\n\n…and {dropped} more {suffix}."
        out = template.replace(PLACEHOLDER, block)
        if len(out) <= max_chars:
            return out

    # Frame alone exceeds the cap: hard-truncate.
    return template.replace(PLACEHOLDER, "")[:max_chars]
