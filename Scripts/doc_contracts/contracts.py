# SPDX-License-Identifier: GPL-3.0-or-later
"""Text contracts over Echo's user-facing docs and in-app help strings.

These assertions used to live in the EchoTests Swift target
(SettingsHelpPathTests, TimelineLanguageCleanupTests). They never imported a
line of app code — they opened files by path and matched substrings — yet
running them cost a full simulator build. Here they run in well under a second
with no Xcode, so a stale settings path or a resurrected "Timeline tab" is
caught before the build gate starts rather than forty minutes into it.

Keep this as the single home for these checks. Duplicating them back into the
Swift target would let the two copies drift.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

# Repo root: Scripts/doc_contracts/contracts.py -> Scripts/doc_contracts -> Scripts -> root
REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class FileContract:
    """Substrings a single file must and must not contain."""

    path: str
    must_contain: tuple[str, ...] = ()
    must_not_contain: tuple[str, ...] = ()
    reason: str = ""


# ---------------------------------------------------------------------------
# Settings information architecture
#
# The in-app help, the two published manuals, and ARCHITECTURE.md all name
# Settings paths. When the Settings tree is reorganized these drift silently:
# nothing crashes, the user just follows directions to a screen that no longer
# exists. The must_not_contain entries are the specific pre-reorganization
# paths, so a copy-paste from an old doc fails loudly.
#
# Note the arrow styles differ on purpose: `>` in Swift help source and
# ARCHITECTURE.md, `→` in the Markdown manual, and `→` with HTML-escaped
# ampersands in the rendered HTML manual.
# ---------------------------------------------------------------------------

SETTINGS_PATH_CONTRACTS: tuple[FileContract, ...] = (
    FileContract(
        path="EchoCore/Views/HelpContent.swift",
        must_contain=(
            "Settings > Controls > Phone Player Settings",
            "Settings > Now Playing > Playback Defaults",
            "Settings > Now Playing > Playback Defaults > Smart Rewind",
            "Settings > Controls > Watch App Settings",
        ),
        must_not_contain=(
            "Settings > Phone Controls",
            "Settings > Playback > Default Speed",
            "Settings > Smart Rewind",
            "Settings > Watch App",
        ),
        reason="in-app help must name the current Settings paths",
    ),
    FileContract(
        path="docs/guides/user-manual.md",
        must_contain=(
            "Settings → Controls → Phone Player Settings",
            "Settings → Now Playing → Playback Defaults → Smart Rewind",
            "Settings → Advanced & Privacy → Advanced → Context Memory",
            "Settings → Now Playing → Playback Defaults",
            "Settings → Study & Notes",
        ),
        must_not_contain=(
            "Settings → Player Controls",
            "Settings → Smart Rewind",
            "Settings → Privacy & Location",
            "Settings → Study —",
        ),
        reason="the Markdown manual must name the current Settings paths",
    ),
    FileContract(
        path="docs/manual.html",
        must_contain=(
            "Settings → Controls → Phone Player Settings",
            "Settings → Now Playing → Playback Defaults → Smart Rewind",
            "Settings → Advanced &amp; Privacy → Advanced → Context Memory",
            "Settings → Now Playing → Playback Defaults",
        ),
        must_not_contain=(
            "Settings → Player Controls",
            "Settings → Smart Rewind",
            "Settings → Privacy &amp; Location",
            "Settings → Study —",
        ),
        reason="the published HTML manual must name the current Settings paths",
    ),
    FileContract(
        path="ARCHITECTURE.md",
        must_contain=(
            "Settings > Controls > Phone Player Settings > Layout",
            "SettingsView` is a thin app-level shell organized by user intent",
            "Now Playing, Appearance, Controls, Library & Accounts, Study & Notes, "
            "Advanced & Privacy, and Support & About",
            "PlayerMoreMenu` in the `BottomToolbarView` dock holds Chapters",
        ),
        must_not_contain=(
            "Sleep-timer submenu, and Settings",
            "submenu, and Settings",
        ),
        reason="ARCHITECTURE.md must describe the current Settings shell",
    ),
)


# ---------------------------------------------------------------------------
# Removed Timeline tab
#
# The Timeline tab and its toolbar button were removed in the 2-tab overhaul.
# Docs and help text that still describe them send users looking for UI that
# is not there, so every user-facing surface is swept for the old vocabulary.
# ---------------------------------------------------------------------------

TIMELINE_FORBIDDEN: tuple[str, ...] = (
    "Timeline tab",
    "TimelineTab",
    "Timeline toolbar",
    "Timeline and Reader tabs",
    "timeline, and bookmark",
    "timelineButton",
    "Timeline feed cells",
)

TIMELINE_SWEPT_FILES: tuple[str, ...] = (
    "EchoCore/Views/HelpContent.swift",
    "EchoCore/Views/PhonePlayerSettingsView.swift",
    "EchoCore/Localizable.xcstrings",
    "ARCHITECTURE.md",
    "docs/guides/user-manual.md",
    "docs/manual.html",
    "docs/guides/focus-field-guide.md",
    "docs/focus.html",
)


def all_contracts() -> tuple[FileContract, ...]:
    """Every contract, with the Timeline sweep expanded to one entry per file."""
    timeline = tuple(
        FileContract(
            path=path,
            must_not_contain=TIMELINE_FORBIDDEN,
            reason="must not describe the removed Timeline tab",
        )
        for path in TIMELINE_SWEPT_FILES
    )
    return SETTINGS_PATH_CONTRACTS + timeline


@dataclass
class Violation:
    path: str
    kind: str  # "missing", "forbidden", or "unreadable"
    needle: str
    reason: str = ""

    def __str__(self) -> str:
        if self.kind == "unreadable":
            return f"{self.path}: cannot be read ({self.needle})"
        if self.kind == "missing":
            return f"{self.path}: missing required text {self.needle!r} — {self.reason}"
        return f"{self.path}: contains forbidden text {self.needle!r} — {self.reason}"


def check(repo_root: Path | None = None) -> list[Violation]:
    """Run every contract against the working tree, newest failure last."""
    root = repo_root or REPO_ROOT
    violations: list[Violation] = []
    cache: dict[str, str | None] = {}

    for contract in all_contracts():
        if contract.path not in cache:
            target = root / contract.path
            try:
                cache[contract.path] = target.read_text(encoding="utf-8")
            except OSError as error:
                cache[contract.path] = None
                violations.append(
                    Violation(contract.path, "unreadable", str(error))
                )
        text = cache[contract.path]
        if text is None:
            continue

        for needle in contract.must_contain:
            if needle not in text:
                violations.append(
                    Violation(contract.path, "missing", needle, contract.reason)
                )
        for needle in contract.must_not_contain:
            if needle in text:
                violations.append(
                    Violation(contract.path, "forbidden", needle, contract.reason)
                )

    return violations
