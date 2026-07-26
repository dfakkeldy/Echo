# Agent guide for Echo

Echo is a Swift and SwiftUI audiobook study player with iOS, macOS, watchOS,
widget, command-line, and Python transcript-tooling surfaces.

## Project boundaries

- Preserve the current deployment floors: iOS 18, macOS 15, and watchOS 11.
- Use the repository's Swift 6 concurrency settings and existing observation
  architecture. App targets use default Main Actor isolation; keep expensive
  media, database, and transcript work off the UI actor.
- Prefer concrete constructor or closure injection. Add a protocol only when a
  real second implementation or a wired test double needs it.
- Do not introduce a third-party dependency without user authorization.
- Keep secrets, private book content, transcripts, and generated study material
  out of commits and public artifacts.
- Preserve localization and accessibility behavior when changing user-facing
  UI. Add or update tests for changed core behavior.

## Working in the codebase

- Read `ARCHITECTURE.md` when the task changes architecture, release mechanics,
  or the headless CLI. Read only the other documents relevant to the task.
- Follow established patterns in the touched subsystem. Prefer current APIs
  available at the deployment target, but do not turn a focused change into
  nearby modernization.
- Keep SwiftUI views focused on presentation and lightweight interaction. Put
  reusable media, persistence, alignment, and transcript behavior in testable
  concrete types.
- Use structured concurrency and propagate cancellation where work is
  cancellable. Avoid blocking cooperative threads.
- Use parameterized database operations and production-safe logging.
- Update documentation when the change makes existing documentation inaccurate;
  documentation work is not an automatic side task.

## Verification

- Run the narrowest relevant tests first. The primary unit-test gate is
  `make test`; edit/test loops can use `make build-tests` followed by
  `make test-only FILTER=EchoTests/<Suite>`.
- Build `echo-cli` with `make echo-cli`; the Make target carries required release
  and compiler settings.
- UI tests are intentionally excluded from the Echo scheme's test action.
- Scale verification to the change. Instruction-only or documentation-only
  edits do not require an Xcode build.

## Repository workflow

- Echo uses `feature/* -> nightly -> weekly -> main`.
- Normal feature work branches from and opens a PR to `nightly`. Promotion PRs
  move `nightly` to `weekly`, then `weekly` to `main`; open one only when asked.
- Hotfixes branch from and PR to `main`, then flow back to `weekly` and `nightly`.
- Never push directly to `main`, `weekly`, or `nightly`.
- Before editing, inspect the branch, upstream, and working tree. Preserve
  unrelated changes and do not rewrite user-owned history.
- Use coherent Conventional Commits. Publish only when the task type and user
  request call for it; do not auto-rebase or force-push as a standing rule.
- After opening or updating a PR, report hosted CI as passing, failing, pending,
  or blocked. CI, merge, deployment, installation, and device acceptance are
  separate states.
