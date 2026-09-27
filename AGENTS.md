# Echo

Open-source (GPL-3.0) audiobook study player for iOS, macOS, and watchOS, with
widgets, the `echo-cli` command-line tool, and Python transcript tooling.
Shared app logic lives in `Shared/`. `ARCHITECTURE.md` covers the architecture,
release mechanics, and the CLI.

## Commands

- `make test` runs the unit tests. For a faster loop: `make build-tests`, then
  `make test-only FILTER=EchoTests/<Suite>`.
- `make echo-cli` builds the CLI. Use it instead of a bare
  `xcodebuild -scheme echo-cli`; the target carries required compiler settings.
- UI tests are not part of the scheme's test action.

## Conventions

- Deployment floors: iOS 18, macOS 15, watchOS 11. Swift 6 with default
  MainActor isolation in app targets; keep media, database, and transcript work
  off the main actor.
- Use concrete types with constructor or closure injection. Add a protocol only
  when there is a second real implementation. Test through in-memory services
  such as `DatabaseService(inMemory:)`.
- Each `AutoAlignmentService` run replaces its own previous automatic anchors.
- Ask before adding a third-party dependency.
- Never commit private book content, transcripts, generated study material, or
  secrets.

## Branches

`feature/*` → `nightly` → `weekly` → `main`. Feature PRs target `nightly`.
Hotfixes branch from `main` and are merged back down. Open promotion PRs only
when asked.
