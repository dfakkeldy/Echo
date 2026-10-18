# Nightly Renderer Auto-Tracker — Design

**Date:** 2026-07-19 (refreshed 2026-08-15)
**Status:** Design only — **not implemented.** Approved as a design after adversarial
code review; landed as a durable record, not as a commitment to build.
**Author:** Dan (with Claude)

> **Revision note (v2, 2026-07-19):** A three-lens adversarial review against the real code
> (`Scripts/echo_renderer/*` and the skill's `echo_installed_renderer.py` + shell wrappers)
> corrected six substantive issues folded into this version: the selector is **per-source-SHA**
> (not one global pointer); `install` stdout does **not** emit `renderVersion`; the
> pronunciation-SHA default belongs in the **shell wrappers**, not the Python resolver; the
> pointer path must be **derived from the renderer root** (not a hard-coded `~/…` absolute) to
> stay test-hermetic, and existing fixtures must migrate; pruning is a **new tracker-owned FS
> op with a concurrency story**; and `--pin` + the multi-channel `channel` field were dropped
> as YAGNI.

> **Revision note (v3, 2026-08-15):** Salvaged from the abandoned branch
> `feat/nightly-renderer-auto-tracker` and refreshed against `origin/nightly` at `700eb1e4`.
> Every settled decision in §2 and §4 was re-verified against today's code and still holds.
> What changed is **references, not reasoning**: the consuming skill was renamed
> `custom-learning-audiobook` → `echo-narration`; `echo_learning_pilot_narrate.sh` was deleted
> and its role folded into `echo_pronunciation_narrate.sh` + `echo_pronunciation_preflight.sh`;
> §3's starting state was re-derived from the live store; and every cited line number was
> re-resolved. One **new** design question surfaced during the refresh and is recorded in
> §4.3a — the acceptance gate is now a *set* of three grandfathered installer SHAs, not the
> single constant this design was written against. That question is open and must be settled
> before implementation.

## 1. Context & Goal

Echo's **versioned renderer installer** (`Scripts/echo_renderer/`, merged to `nightly`
2026-07-18 via PR #457 `24794370` + #458 `72d977ee`) builds, verifies, promotes, and repairs
SHA-locked, content-addressed packages of the `echo-cli` narration renderer into a local store
at `<renderer-root>/<40-hex source SHA>/<64-hex manifest SHA>/` (default renderer-root
`~/Library/Application Support/Echo/Renderers`). The explainer **`echo-narration`** production
skill (`~/Developer/explainer-audiobooks/skills/echo-narration/scripts/`) consumes one
**pinned** renderer per governed narration, gated by hard-coded constants in
`echo_installed_renderer.py` (`ACCEPTED_INSTALLER_SOURCE_SHA` line 25 +
`ACCEPTED_INSTALLER_SOURCE_SHAS` lines 26–33; fail-closed check at line 364).

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

## 3. Starting state (re-derived 2026-08-15)

The v2 draft recorded a just-installed `5d473246…` package as the starting point. A month later
that package is **still installed and still not promoted**, and nine further packages have been
installed by hand on top of it. The drift this design exists to remove is now measurable:

- **Store contents:** 16 source-SHA directories, **3.9 GB** total; packages run **~160–222 MB**
  each. Several source SHAs hold two manifests.
- **Newest installed package:** `echoSourceSHA bd89de8d…` (nightly `bd89de8d`, PR #557),
  manifest `c6781a3c565ebcb8a10aa136dd81e729e5a02c37507eeee7ae5346632fe4999a`,
  `installerSourceSHA 8cb1e09d…`, **`renderVersion` 23**, Release, **15 capabilities**, model
  revision `1939ad2a…`. It has **no selector** — installed, not promoted.
- **`5d473246…`** (the v2 starting state) is likewise still unpromoted after a month.
- **Nightly tip is `700eb1e4`**, five commits ahead of the newest installed package.

Two numbers that look interchangeable and are not: the committed test fixture
`Scripts/echo_renderer/test_vectors/canonical-manifest-v1.json` pins **`renderVersion` 15**,
while the live head package is at **23**. The fixture's version is a frozen schema example, not
a statement about what is installed. Both the fixture and the live package agree on the
**15-capability** roster (12 `--flag` capabilities + `export-blocks`, `resolve-voice-plan`,
`verify-sidecar`), which is the number a live probe must reproduce.

Slice 1 would promote a current package and write the first pointer.

## 4. Architecture

Five units, each independently testable.

### 4.1 Accepted-renderer pointer (single source of truth for "what's accepted now")

- **Path — derived from the renderer root, NOT hard-coded absolute:**
  `<renderer_root>/channel-nightly.json`, where `renderer_root` is the same root the installer
  and the skill resolver already compute (default `~/Library/Application Support/Echo/Renderers`,
  honoring `--renderer-root`). This is required for test hermeticity: the resolver's default
  root is passwd-derived and un-redirectable (`canonical_renderer_root`,
  `echo_installed_renderer.py:101`, still builds it from `_effective_account_home()`), so a
  hard-coded `~/…` path would ignore a test's injected `--renderer-root`. Reader signature:
  `accepted_installer_source_sha(renderer_root)`.
- **Schema (schemaVersion 1):**
  ```json
  {
    "schemaVersion": 1,
    "installerSourceSHA": "8cb1e09de81feeb820e23b151b3a5b40efa4c1c5",
    "echoSourceSHA": "bd89de8ddeee96d6c3931c5f1e2d65053ccaba51",
    "manifestSHA256": "c6781a3c565ebcb8a10aa136dd81e729e5a02c37507eeee7ae5346632fe4999a",
    "renderVersion": 23,
    "updatedAt": "2026-08-15T15:46:00-03:00"
  }
  ```
  - **Invariant:** for tracker-written pointers `installerSourceSHA == echoSourceSHA ==` the
    nightly tip. (The example above is taken from the *hand-installed* head package, where the
    two SHAs legitimately differ because the installer was pinned separately — a tracker-written
    pointer would carry the same SHA in both fields.) Both fields exist so the skill can consume
    installer identity (the acceptance gate) and the pronunciation default independently.
  - `manifestSHA256` + `renderVersion` are **informational records** (each book already records
    the exact SHAs it rendered against); the acceptance gate keys only on `installerSourceSHA`.
    (Optional future hardening: cross-verify the promoted manifest against `manifestSHA256`.)
  - **No `channel` field.** Nightly is the only tracked channel; multi-channel is out of scope.
- **Writer:** the tracker only, via a **shared atomic-write helper** — promote `store.py`'s
  private `_atomic_replace_file` (`store.py:692`) to a non-underscore shared helper that both
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
*not* sufficient: it is acquired only inside `install` (around the build, `store.py:359`) and
inside `promote` (around the selector write, `store.py:548`), and neither covers the fetch /
worktree-prep phase where two runs sharing `--worktree-root` could collide.

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
**per-source-SHA** (`<renderer_root>/<sourceSHA>/approved-renderer.json` — `_selector_path`,
`store.py:628`), written only under the promoted source's directory (`store.py:557`). Each
advance creates a *new* per-source selector; older per-source selectors remain untouched and
harmless — the skill only ever reaches a package via the **channel pointer's** `echoSourceSHA`.
The channel pointer, not "the selector," is the single moving pointer the skill follows.

### 4.3 Skill changes — two files (corrected)

The acceptance gate lives in the Python resolver; the pronunciation-SHA default lives in the
shell wrappers. These are separate files, all under
`~/Developer/explainer-audiobooks/skills/echo-narration/scripts/`.

**(a) Python resolver `echo_installed_renderer.py`:**

> **Open question raised by the 2026-08-15 refresh — settle before implementing.** When v2 was
> written the gate was a single constant. Today it is a **frozenset of three grandfathered
> installer SHAs** (`ACCEPTED_INSTALLER_SOURCE_SHAS`, lines 26–33: `2f23acee…`, `d7f27b02…`,
> and `ACCEPTED_INSTALLER_SOURCE_SHA = 8cb1e09d…`), and line 364 is a **membership** test, not
> an equality test. Collapsing that set to the pointer's single `installerSourceSHA` is the
> design's intent — the tracker is precisely what makes a manual grandfather list unnecessary —
> but it immediately makes every already-installed package built by a *retired* installer SHA
> unresolvable. That is believed acceptable, because the pointer by construction names a package
> that is installed **and** promoted, and §7's manual rollback rewrites `installerSourceSHA` and
> `echoSourceSHA` together, so an older package stays reachable through the documented rollback
> path. Confirm this before writing code; the alternative (pointer SHA ∪ a shrinking legacy set)
> is strictly more machinery and should not be adopted without a demonstrated need.

- Replace the constants with `accepted_installer_source_sha(renderer_root)` that reads
  `<renderer_root>/channel-nightly.json` and returns `installerSourceSHA`. It **must RAISE**
  (`ValueError`) on missing/unreadable/corrupt/short-hex — never return a sentinel — so the
  line-364 gate stays fail-closed (`main()` maps `ValueError` → exit **65**). The manifest's
  `installerSourceSHA` is already validated as 40-hex, so a raised/garbage value can never
  coincidentally match.
- Line-364 check becomes
  `if installer_source_sha != accepted_installer_source_sha(renderer_root): raise …`. Use the
  `renderer_root` the resolver already resolves (so a test's `--renderer-root` yields a hermetic
  pointer).
- **Recovery message** `_operator_install_recovery` (`echo_installed_renderer.py:793`, which
  interpolates the constant at line 798) must **not** call the resolver (a broken-pointer failure
  would re-raise *inside* the `except` block at line 842, producing an unhandled traceback and
  losing the contracted exit 65 + the hint). Resolve defensively: interpolate the accepted SHA
  only in the wrong-SHA case (pointer readable); on the missing/corrupt case substitute a literal
  placeholder ("`<no accepted renderer pointer — run make track-renderer-nightly>`").
- Per-render SHA emission (`ECHO_RENDERER_MANIFEST_SHA256`, `ECHO_CLI_SHA256`,
  `ECHO_RESOURCES_SHA256` — declared lines 53/57/59, emitted lines 178/182/184) is unchanged;
  downstream shell parsing records them per book unchanged.

**(b) Shell wrappers `echo_pronunciation_preflight.sh` + `echo_pronunciation_narrate.sh`:**

> The v2 draft named `echo_learning_pilot_narrate.sh` as the second wrapper. That script was
> **deleted** during the skill rename; `tests/test_echo_narration_lean.py:30` now asserts it
> stays deleted. Its role is split across `echo_pronunciation_narrate.sh` and the preflight.

- `APPROVED_ECHO_PRONUNCIATION_SHA` is required/validated in **these wrappers** (not the Python;
  it appears 0 times there) and passed to the resolver as `--source-sha`. Preflight requires it
  at lines 107–112 and re-validates it at lines 531–543. For hands-off "always latest": when it
  is unset, read `<renderer_root>/channel-nightly.json`'s `echoSourceSHA` in the wrapper (before
  calling the resolver) and export it. The existing "must equal installed source" gate
  (`echo_pronunciation_preflight.sh:837`) still applies and is satisfied because the pointer's
  `echoSourceSHA` == the promoted package's source.
- `echo_pronunciation_narrate.sh` consumes the resolved identity rather than re-deriving it —
  it forwards `--installer-source-sha "$APPROVED_ECHO_INSTALLER_SHA"` and
  `--echo-source-sha "$ECHO_SOURCE_SHA"` into the renderer-state arguments (lines 263–264), so
  the pointer default only has to be established once, upstream, in the preflight.

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
  selectors, `.quarantine-<token>` directories from `repair`, and any unrecognized entries at
  the store root.
- **Keep:** the package named by the current channel pointer (`sourceSHA`, `manifestSHA`)
  **always**, plus the most recent `--keep` (default 3) packages by mtime; delete older package
  directories (**~160–222 MB each** as measured 2026-08-15).
- **Concurrency:** a narrate resolves a package holding only the per-source **selector** lease
  (`_leased_selector`, `echo_installed_renderer.py:126`), then reads the package's manifest and
  files **unleased** (`parse_manifest`, line 144). So before deleting a package the tracker
  acquires that source's selector lease and never deletes the pointer's current package. Deletes
  are best-effort; the pointer's package is never a delete candidate.

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
        (preflight defaults source SHA from pointer.echoSourceSHA when unset)
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
| Disk accumulation | pruning keeps pointer's package + last N; skips pointer/selector/quarantine/non-package entries. |
| Rollback needed | **manual:** `promote` an older still-present package for its source, then rewrite the pointer atomically — setting `installerSourceSHA` and `echoSourceSHA` together to that package's own pair (old package retained by `--keep`). No `--pin`. |

## 8. Testing

Stdlib unit tests (mirrors existing `Scripts/echo_renderer/tests/`):
- **Pointer:** write/read round-trip, atomic replace, corrupt/missing raises, schema validation,
  path derived from `renderer_root` (temp-root hermetic).
- **`track-nightly`** (git/make/`install` stubbed): no-op (tip == pointer), advance (writes
  pointer via `install --promote`), build-fail (pointer unchanged, worktrees cleaned), `--dry-run`
  (no build/write), run-lock contention (clean exit 0), fetch-fail (exit 74), prune (keeps
  pointer's package + last N, **skips the pointer file + selectors**).
- **Existing CLI contract test must be updated:**
  `Scripts/echo_renderer/tests/test_cli.py:153`
  (`test_builds_a_parser_with_all_four_subcommands`) asserts the parser's subcommand set is
  exactly `{install, verify, promote, repair}`. Adding `track-nightly` fails it by design; the
  update is part of the change, not an incidental fix.
- **Skill resolver** (explainer-audiobooks suite): reads pointer from injected `--renderer-root`;
  fail-closed (raises) on missing/corrupt; recovery message survives a broken pointer (exit 65 +
  placeholder). **Migrate** the existing constant-pinned fixtures to write a matching pointer
  into the temp root so they stay green — note the suite was renamed alongside the skill
  (`tests/test_echo_narration_runtime.py`, `tests/test_echo_narration_contract.py`,
  `tests/test_echo_narration_lean.py`), so re-derive the fixture list rather than reusing the
  v2 draft's `test_custom_learning_audiobook_echo_runtime.py` name.
- **Shell wrappers:** pronunciation-SHA default read from the pointer when unset.
- **Operator acceptance (manual, once):** let the agent fire against a moved nightly; confirm the
  pointer + per-source selector advanced and a smoke narrate resolves the new package.

## 9. Surfaces / PRs

- **Echo repo** → PR into `nightly`: `track-nightly` subcommand + shared atomic-write helper +
  pointer writer + prune + run-lock + tests (including the `test_cli.py` subcommand-set update)
  + `Makefile` target `track-renderer-nightly` + launchd plist template + guide update
  (`docs/guides/versioned-echo-renderer.md` §9) + this spec.
- **explainer-audiobooks** → PR into `main`: resolver reads pointer + recovery-message fix +
  shell-wrapper pronunciation default + fixture migration + tests.
- **Local (not in a repo):** install the LaunchAgent from the committed template.

## 10. Slicing

- **Slice 1 — foundation (get-current-now):** shared atomic-write helper + pointer schema/writer
  + resolver reads pointer (raises on missing) + recovery-message fix + shell-wrapper
  pronunciation default + **migrate existing fixtures** + promote a current package + write the
  initial pointer. Outcome: on latest nightly, fail-closed against the pointer, existing tests
  green. *No automation yet.*
- **Slice 2 — automation:** `track-nightly` subcommand (idempotent worktrees + `install --promote`
  + stdout/manifest parse + pointer write) + run-lock + prune + launchd agent + Makefile target
  + guide/plist template + orchestrator tests.

## 11. Confirmed defaults

- Cadence: **daily 06:00 machine-local time** (Halifax on this Mac). Tunable.
- Prune keep-count: **3**.
- Notification: **log always; macOS notification (`osascript`) on failure only**; a successful
  advance is logged, silent.
- Pointer filename: `channel-nightly.json` at the renderer-store root (single channel;
  multi-channel out of scope).

## 12. Status of the original branch (2026-08-15)

`feat/nightly-renderer-auto-tracker` was abandoned before implementation. Only this design doc
was salvaged. Deliberately **not** salvaged:

- **`Scripts/echo_renderer/fsops.py` + `tests/test_fsops.py`** (commits `75d62f72`, `3b4b708b`) —
  a pure no-op code motion that duplicates `store.py:692` (`_atomic_replace_file`) and
  `store.py:955` (`_fsync_directory`) verbatim. The extraction only earns its place as Task 1 of
  the tracker itself (§4.1's shared helper); landing it alone adds a second copy of live code
  with no consumer.
- **The 1337-line implementation plan** (commit `650ac92d`) — its Echo-side tasks and the
  schemaVersion-1 pointer schema survive here in §4.1/§4.2, but its skill-side tasks target the
  pre-rename paths and the deleted `echo_learning_pilot_narrate.sh`, and its scratch worktree
  path `~/Developer/eab-channel-pointer` no longer exists. Re-derive a plan from this spec rather
  than refreshing that one.
