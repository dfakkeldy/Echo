# Nightly Renderer Auto-Tracker — Design

**Date:** 2026-07-19
**Status:** Approved (brainstorming) — revised after adversarial code review; pending final spec review → implementation plan
**Author:** Dan (with Claude)

> **Revision note (v2):** A three-lens adversarial review against the real code
> (`Scripts/echo_renderer/*` and the skill's `echo_installed_renderer.py` + shell wrappers)
> corrected six substantive issues folded into this version: the selector is **per-source-SHA**
> (not one global pointer); `install` stdout does **not** emit `renderVersion`; the
> pronunciation-SHA default belongs in the **shell wrappers**, not the Python resolver; the
> pointer path must be **derived from the renderer root** (not a hard-coded `~/…` absolute) to
> stay test-hermetic, and existing fixtures must migrate; pruning is a **new tracker-owned FS
> op with a concurrency story**; and `--pin` + the multi-channel `channel` field were dropped
> as YAGNI.

## 1. Context & Goal

Echo's **versioned renderer installer** (`Scripts/echo_renderer/`, merged to `nightly`
2026-07-18 via PR #457 `24794370` + #458 `72d977ee`) builds, verifies, promotes, and repairs
SHA-locked, content-addressed packages of the `echo-cli` narration renderer into a local store
at `<renderer-root>/<40-hex source SHA>/<64-hex manifest SHA>/` (default renderer-root
`~/Library/Application Support/Echo/Renderers`). The explainer / `custom-learning-audiobook`
production skill consumes one **pinned** renderer per governed narration, gated by a hard-coded
constant `ACCEPTED_INSTALLER_SOURCE_SHA` in
`skills/custom-learning-audiobook/scripts/echo_installed_renderer.py` (currently the pre-merge
`2f23acee…`; fail-closed check at line 352).

**Goal:** the *promoted* renderer, and the installer SHA the skill accepts, always follow
`origin/nightly`'s tip — hands-off — so explainer audiobooks always render against the latest
reviewed nightly `echo-cli`.

**Non-goals:** changing the installer's content-addressing / integrity model; distributing
renderers off-machine, code signing, or notarization (store stays local-only); multi-channel
support (nightly is the only tracked channel — YAGNI); touching `SlideshowFrameRenderer`.

**Constraints:** the renderer store and the skill both run on Dan's Mac; `make echo-cli`
(Release) is memory-gated on a 16 GB machine; `nightly` is protected, CI-gated ("Build gate +
tests"), and PR-reviewed — that is the trust basis that makes auto-tracking the tip acceptable.

## 2. Decisions (settled during brainstorming)

| Axis | Decision |
|---|---|
| Refresh trigger | **Scheduled local job** (launchd LaunchAgent on Dan's Mac). |
| Promote gate | **Auto-promote on successful publish** (no extra `verify`/smoke gate). `install`'s built-in capability live-probe is the structural floor: a failed build/probe publishes nothing, so there is nothing to promote. |
| Skill sync | **Channel-pointer file** at the renderer-store root; the skill reads it instead of a hard-coded constant. |
| Scope | Full auto-tracker (both slices). Slice 1 first so Dan is on latest nightly before the automation is finished. |

## 3. Current starting state (already in place)

A latest-nightly package is **installed but not promoted** (produced during this session):

- source / installer SHA: `5d473246c8f8209a05c3a4fa47e668ead1b9e54d` (nightly tip)
- manifest SHA: `55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5`
- `renderVersion` 15, Release, all 11 capabilities, model revision `1939ad2a…`
- selector: **not promoted** (`selectorUpdated=false`)

Slice 1 promotes this and writes the first pointer.

## 4. Architecture

Five units, each independently testable.

### 4.1 Accepted-renderer pointer (single source of truth for "what's accepted now")

- **Path — derived from the renderer root, NOT hard-coded absolute:**
  `<renderer_root>/channel-nightly.json`, where `renderer_root` is the same root the installer
  and the skill resolver already compute (default `~/Library/Application Support/Echo/Renderers`,
  honoring `--renderer-root`). This is required for test hermeticity: the resolver's default
  root is passwd-derived and un-redirectable, so a hard-coded `~/…` path would ignore a test's
  injected `--renderer-root`. Reader signature: `accepted_installer_source_sha(renderer_root)`.
- **Schema (schemaVersion 1):**
  ```json
  {
    "schemaVersion": 1,
    "installerSourceSHA": "5d473246c8f8209a05c3a4fa47e668ead1b9e54d",
    "echoSourceSHA": "5d473246c8f8209a05c3a4fa47e668ead1b9e54d",
    "manifestSHA256": "55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5",
    "renderVersion": 15,
    "updatedAt": "2026-07-19T18:34:45-03:00"
  }
  ```
  - **Invariant:** for tracker-written pointers `installerSourceSHA == echoSourceSHA ==` the
    nightly tip. Both fields exist so the skill can consume installer identity (the acceptance
    gate) and the pronunciation default independently, even though they coincide here.
  - `manifestSHA256` + `renderVersion` are **informational records** (each book already records
    the exact SHAs it rendered against); the acceptance gate keys only on `installerSourceSHA`.
    (Optional future hardening: cross-verify the promoted manifest against `manifestSHA256`.)
  - **No `channel` field.** Nightly is the only tracked channel; multi-channel is out of scope.
- **Writer:** the tracker only, via a **shared atomic-write helper** — promote `store.py`'s
  private `_atomic_replace_file` (store.py:679) to a non-underscore shared helper that both
  `promote` and the tracker import (temp file + fsync + `os.replace`), so the two stay in
  lock-step instead of coupling to a private API.
- **Reader:** the skill resolver (§4.3a). Missing/unreadable/corrupt ⇒ resolver **raises**
  (fail closed).

### 4.2 `track-nightly` orchestrator (new `echo_renderer.cli` subcommand)

Runs from a stable Echo clone (the main clone on `nightly`, invoked by launchd). It orchestrates
worktrees + the existing `install`/`promote` primitives; it does not reimplement them.

**Inputs (flags, defaults):** `--echo-repo` (`~/Developer/Echo`), `--worktree-root`
(`~/Developer/InstallWorktrees`), `--renderer-root` (default store root), `--build-gate`,
`--keep` (prune count, 3), `--dry-run`. *No `--pin`* — rollback is a documented manual step (§7).

**Run-lock (mandatory):** acquire a single tracker-level lock (flock on a pidfile under the
store root) at entry, held across the **entire** orchestration (fetch → worktree prep → install
→ promote → pointer → prune). On contention: log "another track run in progress" and **exit 0
(clean skip)** — distinct from the store's lease-contention exit 75. The store's `LeaseSet` is
*not* sufficient: it is acquired only inside `install`, around the build, and does not cover the
fetch / worktree-prep phase where two runs sharing `--worktree-root` could collide.

**Algorithm:**
1. Acquire the run-lock (contention → exit 0 skip).
2. `git -C <echo-repo> fetch origin nightly`; on failure → exit **74** (OSError-class), no
   changes. `TIP = rev-parse origin/nightly`.
3. Read the pointer. A **missing/unreadable/corrupt pointer is treated as "not up to date"**
   (proceed) — distinct from the skill's fail-closed behavior. If
   `TIP == pointer.installerSourceSHA` ⇒ log "up to date", release lock, exit 0 (**no build**).
4. **Idempotent worktrees:** create-or-reset two detached worktrees at `TIP` under
   `--worktree-root` (installer + source). If absent: `git worktree add --detach <p> TIP`; if
   present: `fetch` + `reset --hard TIP` + `clean -fdx`. Attest both clean & detached at exactly
   `TIP`.
5. From the installer worktree, run **`install --promote`** — one leased transaction: waits on
   the build gate, `make echo-cli` (Release), live-probes, publishes, and promotes the
   per-source selector atomically (single verify). On any non-zero exit ⇒ **do not write the
   pointer**; clean up worktrees (in a `finally`); log + notify; exit with the install's code.
   *(This bounds "unconditional": a failed build publishes nothing to promote.)*
6. From `install` stdout (sorted `key=value` lines — split on the first `=`) read `sourceSHA`
   and `manifestSHA256`. Read `renderVersion` from the published manifest
   `<renderer_root>/<sourceSHA>/<manifestSHA>/renderer-manifest.json` via
   `echo_renderer.identity.parse_manifest`.
7. Write the pointer atomically (§4.1).
8. Prune (§4.5).
9. Clean up worktrees; release lock; log the advance.

**`--dry-run`:** acquire lock, fetch, compute `TIP`, report whether an advance *would* occur
(`TIP` vs pointer); never build/promote/write/prune; exit 0.

**Exit codes:** reuse the store contract (0 ok / 64 usage / 69 incompatible / 74 OSError incl.
fetch failure / 75 store lease contention). The run-lock's own clean skip is **exit 0**, not 75.

**Selector model (corrected):** the store's `approved-renderer.json` selector is
**per-source-SHA** (`<renderer_root>/<sourceSHA>/approved-renderer.json`), written only under
the promoted source's directory (store.py:615). Each advance creates a *new* per-source
selector; older per-source selectors remain untouched and harmless — the skill only ever reaches
a package via the **channel pointer's** `echoSourceSHA`. The channel pointer, not "the selector,"
is the single moving pointer the skill follows.

### 4.3 Skill changes — two files (corrected)

The acceptance gate lives in the Python resolver; the pronunciation-SHA default lives in the
shell wrappers. These are separate files.

**(a) Python resolver `echo_installed_renderer.py`:**
- Replace the module constant `ACCEPTED_INSTALLER_SOURCE_SHA` (line 25) with
  `accepted_installer_source_sha(renderer_root)` that reads `<renderer_root>/channel-nightly.json`
  and returns `installerSourceSHA`. It **must RAISE** (`ValueError`) on
  missing/unreadable/corrupt/short-hex — never return a sentinel — so the line-352 gate stays
  fail-closed (`main()` maps `ValueError` → exit **65**). The manifest's `installerSourceSHA` is
  already validated as 40-hex, so a raised/garbage value can never coincidentally match.
- Line-352 check becomes
  `if installer_source_sha != accepted_installer_source_sha(renderer_root): raise …`. Use the
  `renderer_root` the resolver already resolves (so a test's `--renderer-root` yields a hermetic
  pointer).
- **Recovery message** `_operator_install_recovery` (line 772) must **not** call the resolver
  (a broken-pointer failure would re-raise *inside* the `except` block, producing an unhandled
  traceback and losing the contracted exit 65 + the hint). Resolve defensively: interpolate the
  accepted SHA only in the wrong-SHA case (pointer readable); on the missing/corrupt case
  substitute a literal placeholder ("`<no accepted renderer pointer — run make
  track-renderer-nightly>`").
- Per-render SHA emission (`ECHO_CLI_SHA256`, `ECHO_RESOURCES_SHA256`,
  `ECHO_RENDERER_MANIFEST_SHA256` env0 outputs, lines 41/47/49) is unchanged; downstream shell
  parsing records them per book unchanged.

**(b) Shell wrappers `echo_pronunciation_preflight.sh` + `echo_learning_pilot_narrate.sh`:**
- `APPROVED_ECHO_PRONUNCIATION_SHA` is required/validated in **these wrappers** (not the Python;
  it appears 0 times there) and passed to the resolver as `--source-sha`. For hands-off "always
  latest": when it is unset, read `<renderer_root>/channel-nightly.json`'s `echoSourceSHA` in the
  wrapper (before calling the resolver) and export it. The existing "must equal installed source"
  gate (preflight.sh:591, pilot:123) still applies and is satisfied because the pointer's
  `echoSourceSHA` == the promoted package's source.

### 4.4 launchd agent

- Plist `~/Library/LaunchAgents/com.echo.renderer.track-nightly.plist` (template committed under
  `Scripts/echo_renderer/launchd/`).
- `StartCalendarInterval` fires at a fixed **machine-local** hour (launchd has no timezone key) —
  default **06:00**, which on this Halifax-time Mac is 06:00 ADT. No causal tie to the 05:20
  release-train (which builds TestFlight and does not necessarily advance `origin/nightly`'s
  tip); 06:00 is simply a daily quiet time. Tunable.
- `RunAtLoad` false. `StandardOutPath`/`StandardErrorPath` →
  `~/Library/Logs/Echo/renderer-track-nightly.log`.
- Invokes `make -C <echo-repo> track-renderer-nightly`. Non-overlap is guaranteed by the
  tracker's own run-lock (§4.2), not by launchd.

### 4.5 Pruning (tracker-owned filesystem operation)

- The store exposes **no** prune/list primitive, so pruning is a **new tracker-owned filesystem
  operation**, run under the tracker run-lock and **outside** the store's `LeaseSet` model
  (documented as such).
- Enumerate **only** entries matching the package layout `<40-hex source>/<64-hex manifest>/`;
  explicitly **skip** the channel pointer file, the per-source `approved-renderer.json`
  selectors, and any unrecognized entries at the store root.
- **Keep:** the package named by the current channel pointer (`sourceSHA`, `manifestSHA`)
  **always**, plus the most recent `--keep` (default 3) packages by mtime; delete older package
  directories (~150–160 MB each).
- **Concurrency:** a narrate resolves a package holding only the per-source **selector** lease,
  then opens package files **unleased** (echo_installed_renderer.py:132). So before deleting a
  package the tracker acquires that source's selector lease and never deletes the pointer's
  current package. Deletes are best-effort; the pointer's package is never a delete candidate.

## 5. Data flow

```
launchd (daily, machine-local) ──► track-nightly:
    acquire run-lock  (contended → log + exit 0 clean skip)
    fetch nightly → TIP        (fetch fail → exit 74)
    pointer missing/corrupt → treat as "not up to date"
    TIP == pointer.installerSourceSHA?  ──yes──► log "up to date", exit 0   (no build)
        │no
        ▼
    worktrees@TIP (create-or-reset) → install --promote  (gated build+probe+publish+promote)
        │fail──► clean worktrees(finally), log+notify, exit≠0; pointer + prior renderer unchanged
        │ok
        ▼
    read sourceSHA/manifestSHA (stdout) + renderVersion (manifest) → write pointer → prune → log

narrate time (skill):
    resolver reads <renderer_root>/channel-nightly.json → accepted installer SHA
        (shell wrapper defaults source SHA from pointer.echoSourceSHA when unset)
    preflight: installed package installerSourceSHA == accepted?  ──no/raise──► FAIL CLOSED (exit 65)
        │yes
        ▼
    echo-cli narrate  (emits ECHO_CLI/RESOURCES/MANIFEST SHA256 per resolve, recorded downstream)
```

## 6. Trust model (explicit)

Auto-tracking relaxes "a human picks the exact reviewed SHA" to "trust `origin/nightly`'s tip,"
acceptable because `nightly` is protected, CI-gated, and PR-reviewed. Integrity is unchanged:
content-addressed packages, twice-attested worktrees, and the capability live-probe still gate
every `install`. Reproducibility is preserved: the pointer names one exact SHA at any instant,
each book records the SHAs it used, and older packages remain on disk for rollback (`--keep`).

## 7. Failure & edge cases

| Case | Behavior |
|---|---|
| `git fetch` fails | exit **74**, no changes; next run retries. |
| Build/probe fails (`install` ≠ 0) | nothing published → **no promote, pointer unchanged**; worktrees cleaned (`finally`); previous renderer stays live; log + notify. |
| Nightly unchanged | no-op before build (cheap `git fetch` only). |
| **Tracker** pointer missing/corrupt | treated as "not up to date" → proceed (build+promote+write). |
| **Skill** pointer missing/corrupt | resolver **raises** → **fail closed**, exit 65 + recovery hint (placeholder-safe). |
| Overlapping scheduled runs | tracker run-lock → second run logs + **exit 0 clean skip** (≠ store's 75). |
| Disk accumulation | pruning keeps pointer's package + last N; skips pointer/selector/non-package entries. |
| Rollback needed | **manual:** `promote` an older still-present package for its source, then rewrite the pointer atomically (old package retained by `--keep`). No `--pin`. |

## 8. Testing

Stdlib unit tests (mirrors existing `Scripts/echo_renderer/tests/`):
- **Pointer:** write/read round-trip, atomic replace, corrupt/missing raises, schema validation,
  path derived from `renderer_root` (temp-root hermetic).
- **`track-nightly`** (git/make/`install` stubbed): no-op (tip == pointer), advance (writes
  pointer via `install --promote`), build-fail (pointer unchanged, worktrees cleaned), `--dry-run`
  (no build/write), run-lock contention (clean exit 0), fetch-fail (exit 74), prune (keeps
  pointer's package + last N, **skips the pointer file + selectors**).
- **Skill resolver** (explainer-audiobooks suite): reads pointer from injected `--renderer-root`;
  fail-closed (raises) on missing/corrupt; recovery message survives a broken pointer (exit 65 +
  placeholder). **Migrate** the existing constant-pinned fixtures
  (`test_echo_installed_renderer.py`, `test_custom_learning_audiobook_echo_runtime.py`) to write
  a matching pointer into the temp root so they stay green.
- **Shell wrappers:** pronunciation-SHA default read from the pointer when unset.
- **Operator acceptance (manual, once):** let the agent fire against a moved nightly; confirm the
  pointer + per-source selector advanced and a smoke narrate resolves the new package.

## 9. Surfaces / PRs

- **Echo repo** → PR into `nightly`: `track-nightly` subcommand + shared atomic-write helper +
  pointer writer + prune + run-lock + tests + `Makefile` target `track-renderer-nightly` +
  launchd plist template + guide update (`docs/guides/versioned-echo-renderer.md`) + this spec.
- **explainer-audiobooks** → PR into `main`: resolver reads pointer + recovery-message fix +
  shell-wrapper pronunciation default + fixture migration + tests.
- **Local (not in a repo):** install the LaunchAgent from the committed template.

## 10. Slicing

- **Slice 1 — foundation (get-current-now):** shared atomic-write helper + pointer schema/writer
  + resolver reads pointer (raises on missing) + recovery-message fix + shell-wrapper
  pronunciation default + **migrate existing fixtures** + promote the already-installed
  `5d473246` package + write the initial pointer. Outcome: on latest nightly, fail-closed against
  the pointer, existing tests green. *No automation yet.*
- **Slice 2 — automation:** `track-nightly` subcommand (idempotent worktrees + `install --promote`
  + stdout/manifest parse + pointer write) + run-lock + prune + launchd agent + Makefile target +
  guide/plist template + orchestrator tests.

## 11. Confirmed defaults

- Cadence: **daily 06:00 machine-local time** (Halifax on this Mac). Tunable.
- Prune keep-count: **3**.
- Notification: **log always; macOS notification (`osascript`) on failure only**; a successful
  advance is logged, silent.
- Pointer filename: `channel-nightly.json` at the renderer-store root (single channel;
  multi-channel out of scope).
