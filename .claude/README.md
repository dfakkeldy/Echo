# Claude Code automations for Echo

This directory configures [Claude Code](https://claude.com/claude-code) for the Echo repo: hooks that enforce machine-safety rules, review subagents, and task skills. Everything here (except `settings.local.json`) is checked in and shared.

## Hooks — `hooks/` (wired in `settings.json`)

| Hook | Event | What it does |
|------|-------|--------------|
| `guard-xcodebuild.sh` | PreToolUse (Bash) | **Blocks** `xcodebuild` commands that violate the 16 GB RAM rules in `CLAUDE.md`: parallel testing enabled, `-jobs` > 5, or two concurrent heavy builds. `make test` / `make build-tests` and safe direct commands pass through. |
| `swift-format-on-edit.sh` | PostToolUse (Edit/Write) | Runs `swift format` on the just-edited `.swift` file using the repo's `../.swift-format` config. Best-effort: it never blocks or alters an edit's success. |

The guard is **segment-aware** — it blanks quoted args, splits on shell operators (`&&`, `;`, `&`, …), and applies its rules to each `xcodebuild` segment, so decoy flags and chained invocations can't slip past it.

**Run the hook tests:**
```bash
make hooks-test          # runs both suites below
bash .claude/hooks/test-guard-xcodebuild.sh
bash .claude/hooks/test-swift-format-on-edit.sh
```

**Disabling:**
- Formatter, one session: `export ECHO_DISABLE_SWIFT_FORMAT=1`
- Formatter, permanently: delete the repo-root `.swift-format` (the hook is config-gated)
- Either hook: remove its block from `settings.json`

## Subagents — `agents/`

| Agent | Invoke it before… |
|-------|-------------------|
| `schema-migration-reviewer` | committing a GRDB schema change (`Shared/Database/`, new `Schema_Vxx`, `registerMigration`). Catches version collisions, unregistered/edited migrations, missing tests, and re-import/re-align consequences. |
| `cross-platform-parity-reviewer` | committing a change to shared logic (`Shared/`, `EchoCore/`). Checks the change landed on every surface that needs it — watchOS, Widget, the macOS `Mac*` counterparts, CarPlay. |

Both are read-only. They run automatically when relevant, or on request: *"use the schema-migration-reviewer on my diff."*

## Skills — `skills/`

| Skill | Invocation | Purpose |
|-------|-----------|---------|
| `/new-schema-migration` | user | Scaffold the next GRDB migration (enum + registration + test) with a collision-proof version number. Bundles `scripts/check-schema-version.sh`. |
| `/doc-sync` | user or model | After a feature/architecture/schema/pipeline change, find which of `ARCHITECTURE.md` / `README.md` / `CHANGELOG.md` / `ROADMAP.md` are now stale and draft the patches. |

Check the next free schema version any time:
```bash
bash .claude/skills/new-schema-migration/scripts/check-schema-version.sh
```

## Settings files

- **`settings.json`** — shared, checked in. Owns the hooks above.
- **`settings.local.json`** — personal, git-ignored. Owns your local permission allow-list only (no hooks).
