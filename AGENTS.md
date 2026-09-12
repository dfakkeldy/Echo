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
- Use coherent Conventional Commits; do not auto-rebase or force-push as a
  standing rule.
- Requested repository changes finish with a ready PR and auto-merge on green
  required CI, using the supported merge method and respecting branch protections.
  If native auto-merge is unavailable, merge the verified PR head normally after
  reported checks pass. If CI is absent or blocked, leave the ready PR and report
  that limitation once. Do not ask for another merge approval for ordinary work.
- After opening or updating a PR, report hosted CI as passing, failing, pending,
  or blocked. CI, merge, deployment, installation, and device acceptance are
  separate states.

## Device testing and nightly delivery

Routine native changes finish with the PR and green-CI merge; the established
nightly pipeline handles delivery to the Nightly TestFlight group. The user relies
on automatic updates and tests when convenient, possibly days or weeks later.
Do not request device verification, append manual acceptance checklists, send
reminders, or block subsequent changes because earlier builds remain untested.
Run proportionate automated/simulator checks and fix device issues when reported.
Overnight iPhone testing is optional, only when the user offers it for that session.

Do not claim device behavior or installation was verified without evidence.
Explicitly requested device investigations may need specific device evidence;
ordinary uncertainty is not a completion gate. Weekly/stable promotion and public
release remain separate, explicitly requested work.
