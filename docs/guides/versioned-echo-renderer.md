# The Versioned Echo Renderer Installer

`Scripts/echo_renderer/` builds, verifies, promotes, and repairs **content-addressed** `echo-cli` packages — the standalone Release binary that headless narration, m4b export, QA, and sidecar tooling run against. It exists so that narration-time work (`echo-cli narrate`, `echo-cli retag`, `echo-cli verify-sidecar`, and friends) never has to build anything: an operator installs one reviewed, verified renderer package ahead of time, and every headless run afterward just points at it.

This guide is for whoever runs those installs — a developer, or a CI job acting on their behalf. It is not user-facing: nothing here ships in the app.

---

## 1. Why a separate installer exists

Building `echo-cli` from arbitrary source and trusting the result blind is how you end up narrating a book with a binary nobody reviewed. The installer instead:

- pins the two source trees that produced the binary to exact, attested commits;
- builds it fresh, with the make target that is known to produce a correct Release binary (`make echo-cli` — never a bare `xcodebuild`, see `ARCHITECTURE.md` ▸ *Headless CLI export*);
- live-probes the result for the exact capabilities narration-time tooling depends on before publishing anything;
- stores each build under a hash of its own manifest, so two different builds of the same source can coexist side by side and a byte-identical rebuild is a no-op; and
- separates "which package narration-time tooling actually uses" (the **selector**) from "which packages exist on disk" (the **store**), so publishing a new build never silently changes what's already in use.

There is no narration-time build step anywhere in this design. If `echo-cli narrate` (or export, or QA) needs a renderer that isn't installed, that is an operator error to fix by running `install` — the narration code path itself never shells out to `make echo-cli`.

---

## 2. Store layout

```
~/Library/Application Support/Echo/Renderers/
└── <40-hex source SHA>/
    ├── approved-renderer.json            # the selector (see §5)
    └── <64-hex manifest SHA>/            # one renderer package
        ├── echo-cli
        ├── EchoNarrationResources/
        └── renderer-manifest.json
```

- **`<source SHA>`** — the exact 40-character-hex Echo/Swift commit that produced the package.
- **`<manifest SHA>`** — the SHA-256 of the package's own canonical `renderer-manifest.json` bytes. Because the directory name is derived from the manifest's own content, a package cannot be renamed into a different identity without the hash instantly disagreeing with its own directory name — `verify` checks exactly this.
- A renderer package holds **exactly three entries**: `echo-cli`, `EchoNarrationResources/`, and `renderer-manifest.json`. Anything missing or extra is treated as corruption.
- Because packages are content-addressed, the same source SHA can have **multiple sibling `<manifest SHA>` directories** — e.g. two builds a week apart that happened to produce byte-identical output collapse to one publish (`install` is idempotent), while a build that produced *different* bytes at the same source SHA publishes alongside the earlier one rather than overwriting it. `install` always refuses to overwrite an existing package whose bytes disagree with what it just built.

---

## 3. The two independent approved SHAs

Every build/repair call takes **two separate, full 40-character lowercase-hex commit SHAs** — never a branch name, never `HEAD`, and never inferred from whatever a worktree happens to have checked out:

| Variable | What it pins | Worktree it's checked against |
|---|---|---|
| `APPROVED_ECHO_INSTALLER_SHA` | The reviewed `Scripts/echo_renderer/` implementation that is trusted to run `install`/`repair` at all. | `--installer-worktree` |
| `APPROVED_ECHO_PRONUNCIATION_SHA` | The Echo/Swift source tree that `make echo-cli` compiles into the published `echo-cli` + `EchoNarrationResources`. | `--source-worktree` |

These are deliberately independent: the installer tooling being trustworthy and the renderer source being trustworthy are two different reviews, and either one can be a different commit of the same Echo repository (e.g. re-running an older reviewed installer against a newer source, or vice versa).

Both worktrees are attested — clean working tree, `HEAD` at exactly the approved SHA — **twice**: once before the build starts, and again immediately before the package is published. A slow build can't let an intervening, unreviewed commit slip into a published package between those two checks.

---

## 4. Prerequisites: two separate clean worktrees

Because the installer and source SHAs are independent, use **two distinct `git worktree` checkouts of the Echo repository** — never point both flags at the same directory, and never reuse a worktree that has local edits or is mid-rebase.

```bash
# From any existing clone of the Echo repository:
git fetch origin nightly

# Installer worktree: the reviewed Scripts/echo_renderer/ implementation.
git worktree add ~/Developer/echo-renderer-installer <APPROVED_ECHO_INSTALLER_SHA>

# Source worktree: the reviewed Echo/Swift source that becomes echo-cli.
git worktree add ~/Developer/echo-renderer-source <APPROVED_ECHO_PRONUNCIATION_SHA>
```

Both `git worktree add` invocations above check out a *specific commit*, so each worktree starts clean and detached at exactly its approved SHA — no branch, no `HEAD` drift possible before you've even run the installer.

The CLI's Python package (`Scripts/echo_renderer/`) lives *inside* the installer worktree, so every command below is run with that worktree as the current directory.

---

## 5. Running install / verify / promote / repair

All four subcommands are invoked as `python3 -m echo_renderer.cli <subcommand>` with `PYTHONPATH=Scripts` set (so Python can find the `echo_renderer` package under the installer worktree), or via the equivalent `make *-renderer` targets, which set `PYTHONPATH=Scripts` for you and default `--installer-worktree` to the current checkout (`$(CURDIR)`) — so `make install-renderer` / `make repair-renderer` must be run **from inside the installer worktree**.

### 5.1 `install` — build, stage, probe, and publish one package

```bash
cd ~/Developer/echo-renderer-installer

PYTHONPATH=Scripts python3 -m echo_renderer.cli install \
  --installer-worktree ~/Developer/echo-renderer-installer \
  --installer-sha <APPROVED_ECHO_INSTALLER_SHA> \
  --source-worktree ~/Developer/echo-renderer-source \
  --source-sha <APPROVED_ECHO_PRONUNCIATION_SHA>
```

Or via `make`, from the same installer worktree:

```bash
cd ~/Developer/echo-renderer-installer
export APPROVED_ECHO_INSTALLER_SHA=<installer sha>
export APPROVED_ECHO_PRONUNCIATION_SHA=<source sha>
export ECHO_RENDERER_SOURCE=~/Developer/echo-renderer-source
make install-renderer
```

`install` attests both worktrees, leases the installer root, the source root, and `<source>/.build/cli`, re-attests, waits on the shared memory-pressure build gate (`--wait`), runs `make echo-cli` (Release, incremental — see `ARCHITECTURE.md` ▸ *Headless CLI export* for why that exact target matters), copies the built `echo-cli` + `EchoNarrationResources` beside the renderer root, then **live-probes** the staged binary before trusting anything it says about itself:

- `echo-cli --version` must read exactly `ONNX rv<int> (Release)`.
- `echo-cli narrate --help` must list `--cover --sidecar --voice --db --work-dir --jobs --threads --resume --max-chapters --no-pronunciation-review`.
- the `verify-sidecar` subcommand must exist.

It then reads the model policy (§7), requires the staged resource tree to *completely* match the freshly-built output (an incomplete copy is refused, not silently published), writes the canonical `renderer-manifest.json`, re-attests both worktrees one more time, and only then atomically publishes the package to `<source SHA>/<manifest SHA>/`. All three leases are held for the full transaction.

Success prints stable, sorted `key=value` lines to stdout: `executableSHA256`, `installedPath`, `installerSourceSHA`, `manifestSHA256`, `resourcesSHA256`, `sourceSHA` (plus `selectorUpdated` when `--promote` was passed — see §5.3). Installing byte-identical output twice is a no-op that returns the same identity; a build that differs from an existing package at the same directory refuses rather than overwriting it.

### 5.2 `verify` — strictly re-check one already-published package

No worktrees or build needed — this only reads what's on disk and re-probes the live binary.

```bash
PYTHONPATH=Scripts python3 -m echo_renderer.cli verify \
  --source-sha <APPROVED_ECHO_PRONUNCIATION_SHA> \
  --manifest-sha <manifestSHA256 printed by install>
```

```bash
export APPROVED_ECHO_PRONUNCIATION_SHA=<source sha>
export ECHO_RENDERER_MANIFEST_SHA=<manifest sha>
make verify-renderer
```

`verify` re-derives the executable/resource hashes from the bytes on disk, re-decodes the manifest, and re-probes the live binary (`--version`, `narrate --help`, `verify-sidecar`), rejecting any mismatch between what's published and what's actually installed.

### 5.3 `promote` — point the selector at one verified package

```bash
PYTHONPATH=Scripts python3 -m echo_renderer.cli promote \
  --source-sha <APPROVED_ECHO_PRONUNCIATION_SHA> \
  --manifest-sha <manifestSHA256>
```

```bash
export APPROVED_ECHO_PRONUNCIATION_SHA=<source sha>
export ECHO_RENDERER_MANIFEST_SHA=<manifest sha>
make promote-renderer
```

See §6 for what the selector actually is. `promote` re-verifies the target package before writing anything, so the selector can never point at bytes that don't match their own recorded identity.

`install --promote` performs an install and a promote in one call — but it is **only appropriate for a source SHA that has no selector yet** (a first install of that source). Every later build at the same source SHA needs an explicit, separate `promote` call once you've decided that build is the one narration-time tooling should use; `install --promote` would otherwise silently repoint an already-in-use selector the moment a new package finished building, with no independent review step in between.

### 5.4 `repair` — quarantine and rebuild one package identity

```bash
cd ~/Developer/echo-renderer-installer

PYTHONPATH=Scripts python3 -m echo_renderer.cli repair \
  --installer-worktree ~/Developer/echo-renderer-installer \
  --installer-sha <APPROVED_ECHO_INSTALLER_SHA> \
  --source-worktree ~/Developer/echo-renderer-source \
  --source-sha <APPROVED_ECHO_PRONUNCIATION_SHA> \
  --manifest-sha <the manifest SHA to restore>
```

```bash
cd ~/Developer/echo-renderer-installer
export APPROVED_ECHO_INSTALLER_SHA=<installer sha>
export APPROVED_ECHO_PRONUNCIATION_SHA=<source sha>
export ECHO_RENDERER_SOURCE=~/Developer/echo-renderer-source
export ECHO_RENDERER_MANIFEST_SHA=<manifest sha to restore>
make repair-renderer
```

See §8 for exactly what this does — it is the tool for "this published package looks corrupted, rebuild it."

---

## 6. Selector semantics

The **selector**, `<source SHA>/approved-renderer.json`, is the one file narration-time tooling actually reads to decide *which* published package to use — the store can hold many packages per source SHA, but at most one selector per source SHA. It is exactly this canonical JSON, with no other keys:

```json
{"echoSourceSHA": "<40-hex>", "manifestSHA256": "<64-hex>", "schemaVersion": 1}
```

Only `promote` (directly, or via `install --promote`) ever writes it — a plain `install` never touches the selector. Writes go through a sibling temporary file, `fsync`, and `os.replace`, so a reader never observes a half-written selector. Because `promote` re-verifies the target package first, the selector can never end up pointing at a package that fails its own identity check.

As noted in §5.3: use `install --promote` only for a source SHA's first install (no selector exists yet); use a separate, explicit `promote` for every later build you actually want narration-time tooling to switch to.

---

## 7. Model policy: informational, not attested

Every manifest carries a `modelPolicy` block describing the Kokoro ONNX model the renderer expects, read directly from the two governing assignments in `EchoCore/Services/Narration/OnnxKokoroEngine.swift` (`modelRevision`, `expectedModelBytes`):

```json
"modelPolicy": {
  "revision": "<40-hex model revision>",
  "expectedByteCount": 123456789,
  "deliveryMode": "sharedEchoCache",
  "modelBytesAttested": false
}
```

This is **informational only**. `deliveryMode: "sharedEchoCache"` means the model itself is fetched/cached separately (shared across renderer packages, not copied into each one), and `modelBytesAttested: false` is not a placeholder to fix later — it is a permanent, structural statement that the manifest **does not attest** the actual bytes of the cached Kokoro model on disk. Installing or verifying a renderer package says nothing about whether the model cache is intact; that is a separate concern the installer does not check.

---

## 8. Repair and quarantine

`repair` is for one specific situation: a published package under `<source SHA>/<manifest SHA>/` looks wrong (corrupted, tampered with by hand, or otherwise failing `verify`) and you want to rebuild that exact identity from source.

1. **Refuses immediately (exit code `75`) if the target package or its source's selector has a live lease held by another process** — it names which resource is contended rather than blocking or forcing its way past a concurrent install/promote.
2. **Quarantines** any existing directory at `<source SHA>/<manifest SHA>/` by renaming it to `<source SHA>/<manifest SHA>.quarantine-<random hex token>/`. This is a plain rename, not a delete — the old bytes are fully preserved for inspection. Quarantine directories are **never removed automatically** by any part of this tooling; cleaning them up is a manual decision.
3. **Rebuilds** by running the exact same transaction as `install` (§5.1), with promotion deferred until repair's own logic decides what to do with it.
4. **Compares the rebuilt manifest hash to the one you asked to restore:**
   - **Exact match** — the original identity is considered restored. If you passed a promote-equivalent request, the selector is (re-)pointed at it now.
   - **Any other hash** — the rebuild is published as its own new package, sitting *beside* the quarantined original at its own `<manifest SHA>`. The selector is left **completely untouched**, and the command fails with an error reporting both the requested and the rebuilt manifest hashes, stating that the requested identity is **non-resumable** — source has drifted (or the build is no longer reproducible) since that package was originally published, and the old identity cannot be recreated byte-for-byte.

---

## 9. No automatic update, list, or cleanup

The CLI is deliberately narrow: exactly four subcommands exist — `install`, `verify`, `promote`, `repair`. There is no `list`, no `update`, and no automatic cleanup of anything:

- old renderer packages that are no longer selected by any `approved-renderer.json` are never garbage-collected;
- quarantine directories from `repair` (§8) are never removed automatically;
- nothing periodically re-checks or re-verifies an installed package on its own.

Auditing what's on disk, deciding what's safe to delete, and actually deleting it are all manual operator tasks (`ls`/`find`/`rm` against the store layout in §2) — intentionally, so a bug in this tooling can never silently delete a package another process is relying on.

---

## 10. Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — stable, sorted `key=value` lines on stdout. |
| `64` | Usage error: bad flags, a malformed SHA, an unknown subcommand. |
| `65` | Verification / corruption / attestation failure. |
| `69` | The renderer is incompatible with this host (non-Release build, a missing required capability, an unsupported architecture, or a deployment floor above the host's macOS version). |
| `75` | Temporary failure: another process holds a live lease on the same resources (including `repair`'s refuse-if-contended check in §8). Retry once the contention clears. |

---

## 11. Security model: integrity, not authentication

The hashing and attestation throughout this tooling exist to catch **accidental corruption and races among cooperating agents on the same machine** — a partially-copied build mistaken for a finished one, two concurrent installs stepping on each other's staging directory, a hand-edited manifest that no longer matches its own directory name. Every check in §2–§8 is built to catch exactly those failure modes early and loudly.

It is **not** a security boundary against a malicious process. Any process already running as the same user account can read, write, or replace any file this tooling reads or writes, compute any hash it likes, and forge an attestation just as validly as the real installer would — there is nothing here that authenticates *who* is running the installer, only that the bytes it eventually publishes are internally self-consistent.

---

## 12. Local-only today; signing/notarization is a future, out-of-scope path

This installer is **local-only**: there is no code signing and no notarization anywhere in `Scripts/echo_renderer/`, and a published `echo-cli` never leaves the machine that built it — it lives under a per-user `~/Library/Application Support/` directory and is only ever read back by tooling running as that same user.

If Echo ever needed to distribute a prebuilt renderer to *other* users' machines, that would require Apple Developer ID signing and notarization (and almost certainly a different distribution/trust model than "hash matches its own directory name"). That is explicitly **out of scope** for this installer as it exists today — nothing in this design should be read as a substitute for it.
