---
name: doc-sync
description: Use when a change adds or removes a feature, alters the app architecture, changes the database schema, or modifies the Python transcription pipeline in Tools/ — any time Echo's living docs (ARCHITECTURE.md, README.md, CHANGELOG.md, ROADMAP.md) may now be stale. Also use before opening a PR to confirm docs match the code.
---

# Doc Sync

Echo's CLAUDE.md makes documentation sync **CRITICAL**: whenever a feature, architecture, schema, or pipeline change lands, the docs must be updated in the same change. This skill turns that mandate into a concrete check + ready-to-paste snippets.

## The docs and what each owns

| Doc | Owns | Update when |
|-----|------|-------------|
| `ARCHITECTURE.md` | The blueprint — services, data flow, alignment pipeline, DB schema | New/changed service, protocol, migration, or alignment behavior |
| `README.md` | User/contributor-facing overview, setup, feature list | A user-visible feature appears or changes |
| `CHANGELOG.md` | Per-version history (Conventional-Commits style) | Every shippable change |
| `ROADMAP.md` | Planned work, workstreams (WS-x) | A roadmap item ships or is re-scoped |
| `Tools/` (pipeline) | Python transcription generator | The Whisper/transcription pipeline changes |

## Procedure

1. **Scope the change.** `git diff --stat origin/main...HEAD` (or the working diff). Classify each changed area:
   - `Shared/Database/` → schema change → ARCHITECTURE.md + CHANGELOG.md
   - `EchoCore/Services`, `*ViewModels`, `Protocols`, `Shared/` → architecture → ARCHITECTURE.md
   - new view / user-facing behavior → README.md feature list + CHANGELOG.md
   - `Tools/*.py` → pipeline section of README/ARCHITECTURE
   - anything shippable → CHANGELOG.md entry
2. **Detect staleness.** For each affected doc, grep for the symbols/sections the change touches and check whether the prose still matches the code (renamed service, removed flag, new step in the pipeline, new migration version).
3. **Draft the patch.** Produce the exact markdown snippet for each doc — the new/edited section, sized to the change, in that doc's existing voice and heading style. For CHANGELOG.md, follow the existing Conventional-Commits grouping.
4. **Apply or hand off.** If invoked by the user, offer to apply the edits directly. If running inside another task, surface the snippets and remind that CLAUDE.md requires docs to ship with the change.

## Output

A short list: `Doc → section → why it's stale → snippet`. If a doc needs no change, say so explicitly (don't silently skip it). Never claim docs are in sync without having diffed the code against them.
