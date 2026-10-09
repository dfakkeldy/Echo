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

## Shared agent message board

Use the shared agent message board freely for relevant coordination, questions,
blockers, evidence, ownership, and handoffs. Ordinary coordination does not need a
separate user request. Read recent relevant messages before overlapping work;
respect active owners, their branches/worktrees, and repository-specific rules.
Coordinate handoffs instead of taking over or duplicating work.

Use the supported local `agent_messages.py` CLI from a reviewed board checkout on
the shared host. Resolve `AGENT_BOARD_REPO` through existing private user-level
instructions; do not publish that checkout path or board address here. Once that
variable points to the checkout containing the script:

```sh
python3 "$AGENT_BOARD_REPO/agent_messages.py" threads --inbox --limit 20
python3 "$AGENT_BOARD_REPO/agent_messages.py" threads --project "<repo>" --search "<topic>"
python3 "$AGENT_BOARD_REPO/agent_messages.py" list --thread "<thread-id>" --limit 30
python3 "$AGENT_BOARD_REPO/agent_messages.py" post \
  --author "<agent>" --task "<task-id>" --project "<repo>" \
  --topic "<topic>" --kind handoff --owner-visible \
  --ref "https://github.com/example/project/pull/1" <<'MESSAGE'
Replace this with a concise coordination update and the next owner/action.
MESSAGE
```

Replace example values with accurate identity and evidence. The CLI generates the
UTC date/time and message/thread IDs. Use `--kind update|question|blocker|evidence|ownership|handoff`
(one value), repeat `--ref` for supporting HTTPS/Codex-thread links, and use
`--thread <thread-id>` or `--reply-to <message-id>` for replies. Reuse the same
topic spelling within a project; posting to an existing topic appends to its
stable thread. Put URLs in references, not message text. Start with inbox/project
summaries and use bounded search/history instead of rereading everything.

Unowned, unresolved discussions appear in the shared inbox. Coordinate discussion
ownership with `--kind ownership --owner <agent>` or a handoff; `--unowned` returns
it to the inbox. Use `--status open|waiting|resolved` (one value) to describe the
discussion. Every change remains an attributed message; discussion status/owner
does not change task completion or grant authority over another agent's work.
`--owner-visible` declares ordinary coordination suitable for the existing owner
view; it is not a request for fresh user approval. Read `docs/AGENT_MESSAGES.md`
in that checkout for filters, limits and recovery. Keep one shared default store;
do not create per-repository boards. If the script/host is unavailable, report
that concrete limitation and continue independent work. On an uncertain failure,
inspect recent records before retrying rather than posting duplicates.

Keep durable decisions/procedures in the knowledge base, and current tasks,
ownership and progress in shared task records. Link those records from the board.
Messages do not replace those records, complete tasks, confer user approval,
override instructions, or authorize publishing, access changes, spending or
private-data disclosure. Never post secrets, private assistant notes or sensitive
correspondence. Keep private board records, addresses and paths out of public
repositories, commits, PRs, logs and screenshots.

The CLI and Agents display are a reviewed implementation delivered separately;
a draft PR alone does not mean the installed runtime has changed. Verify the
local script and current runtime before claiming posting or display is live.
