# Nightly Renderer Auto-Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the promoted `echo-cli` renderer, and the installer SHA the explainer skill accepts, always tracking `origin/nightly`'s tip via a scheduled local job + a channel-pointer file.

**Architecture:** A pure-stdlib Python `channel-nightly.json` pointer at the renderer-store root becomes the single source of truth for "which installer SHA is accepted." The Echo `echo_renderer` package gains a `set-channel` CLI (promote + write pointer) and a `track-nightly` orchestrator (fetch → build+install+promote → write pointer → prune), driven by a launchd agent. The explainer skill's resolver + shell wrappers read the pointer instead of a hard-coded constant.

**Tech Stack:** Python 3 standard library only (`unittest`, `argparse`, `subprocess`, `fcntl`, `json`, `pathlib`); Bash; `make`; launchd. No third-party dependencies.

**Design spec:** `docs/superpowers/specs/2026-07-19-nightly-renderer-auto-tracker-design.md` (read it first).

## Global Constraints

- **Pure standard library only.** `Scripts/echo_renderer/` is stdlib Python; add no dependencies. Tests are stdlib `unittest` (not pytest, not Swift Testing).
- **Two repos, two PR targets.** Echo changes → PR into `nightly` (`gh pr create --base nightly`). explainer-audiobooks changes → PR into `main`. Never push to protected branches.
- **Conventional Commits** for every commit.
- **The renderer build is `make echo-cli` (Release, incremental) only** — never a bare `xcodebuild`, never wholemodule (it hangs on macOS 26). The store already enforces this; the tracker must not bypass it.
- **`renderVersion` is a JSON integer** (currently 15). Canonical JSON = `sort_keys=True, separators=(",",":"), ensure_ascii=False`, trailing `\n` (`echo_renderer.identity.canonical_json_bytes`).
- **Fail-closed means RAISE, never return a sentinel.** The skill resolver's pointer read must raise `ValueError`/`OSError` (both mapped to exit 65) on any missing/corrupt/short-hex pointer.
- **Pointer path is derived from `renderer_root`** (`<renderer_root>/channel-nightly.json`), never a hard-coded `~/…` absolute — required for test hermeticity.
- **Pointer schema (schemaVersion 1):** keys exactly `{schemaVersion, installerSourceSHA, echoSourceSHA, manifestSHA256, renderVersion, updatedAt}`. For tracker-written pointers `installerSourceSHA == echoSourceSHA ==` the nightly tip.
- **Store SHA validators:** `validate_commit_sha` = 40 lowercase hex; `validate_sha256` = 64 lowercase hex (`echo_renderer.identity`).
- **The already-installed package to promote in Slice 1:** source SHA `5d473246c8f8209a05c3a4fa47e668ead1b9e54d`, manifest SHA `55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5`, `renderVersion` 15.

## File Structure

**Echo repo** (`/Users/dfakkeldy/Developer/Echo`, branch `feat/nightly-renderer-auto-tracker` off `nightly`):
- Create `Scripts/echo_renderer/fsops.py` — public `atomic_replace_file` + `fsync_directory` (extracted from `store.py`).
- Create `Scripts/echo_renderer/channel.py` — channel-pointer path/read/write.
- Modify `Scripts/echo_renderer/store.py` — import the extracted helpers instead of the private copies.
- Modify `Scripts/echo_renderer/cli.py` — add `set-channel` (Slice 1) and `track-nightly` (Slice 2) subcommands.
- Create `Scripts/echo_renderer/runlock.py` — flock run-lock (Slice 2).
- Create `Scripts/echo_renderer/track.py` — orchestrator + worktree management + prune (Slice 2).
- Create tests: `tests/test_fsops.py`, `tests/test_channel.py`, `tests/test_cli_set_channel.py`, `tests/test_runlock.py`, `tests/test_track.py`.
- Modify `Makefile` — add `track-renderer-nightly` target.
- Create `Scripts/echo_renderer/launchd/com.echo.renderer.track-nightly.plist` — LaunchAgent template.
- Modify `docs/guides/versioned-echo-renderer.md` — document channel + tracker.

**explainer-audiobooks repo** (`/Users/dfakkeldy/Developer/explainer-audiobooks`, branch `feat/renderer-channel-pointer` off `main`):
- Modify `skills/custom-learning-audiobook/scripts/echo_installed_renderer.py` — read pointer for the acceptance gate + defensive recovery message.
- Modify `skills/custom-learning-audiobook/scripts/echo_pronunciation_preflight.sh` — pointer helper + default-when-unset (also used by pilot, which sources it).
- Modify `skills/custom-learning-audiobook/scripts/echo_learning_pilot_narrate.sh` — call the default helper before its gate.
- Modify `tests/test_echo_installed_renderer.py` and `tests/test_custom_learning_audiobook_echo_runtime.py` — write a `channel-nightly.json` pointer into their temp roots.

---

# SLICE 1 — Foundation (get onto latest nightly, fail-closed against the pointer)

## Task 1: Extract a shared atomic-write helper (`fsops.py`)

**Files:**
- Create: `Scripts/echo_renderer/fsops.py`
- Modify: `Scripts/echo_renderer/store.py` (remove the private `_atomic_replace_file`/`_fsync_directory` bodies at ~679–710, import from `fsops`; keep call sites working)
- Test: `Scripts/echo_renderer/tests/test_fsops.py`

**Interfaces:**
- Produces: `atomic_replace_file(path: Path, data: bytes, *, mode: int = 0o644) -> None`; `fsync_directory(directory: Path) -> None` in `echo_renderer.fsops`.

- [ ] **Step 1: Write the failing test**

```python
# Scripts/echo_renderer/tests/test_fsops.py
import tempfile
import unittest
from pathlib import Path

from echo_renderer.fsops import atomic_replace_file


class AtomicReplaceFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def test_writes_new_file_with_exact_bytes(self) -> None:
        target = self.root / "pointer.json"
        atomic_replace_file(target, b'{"a":1}\n')
        self.assertEqual(target.read_bytes(), b'{"a":1}\n')

    def test_replaces_existing_file_atomically(self) -> None:
        target = self.root / "pointer.json"
        atomic_replace_file(target, b"old")
        atomic_replace_file(target, b"new")
        self.assertEqual(target.read_bytes(), b"new")
        # no leftover temp files
        self.assertEqual([p.name for p in self.root.iterdir()], ["pointer.json"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_fsops -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'echo_renderer.fsops'`.

- [ ] **Step 3: Create `fsops.py` by moving the helpers verbatim from `store.py`**

```python
# Scripts/echo_renderer/fsops.py
"""Atomic filesystem primitives shared by the store and the channel pointer."""
import os
import secrets
from pathlib import Path


def fsync_directory(directory: Path) -> None:
    """fsync a directory so a rename/create is durable."""
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_replace_file(path: Path, data: bytes, *, mode: int = 0o644) -> None:
    """Atomically replace one file via a sibling temp file, fsync, and os.replace."""
    directory = path.parent
    temp_path = directory / f".{path.name}.{secrets.token_hex(8)}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        file_descriptor = os.open(temp_path, flags, mode)
    except OSError as error:
        raise ValueError(f"cannot create temp file: {temp_path}") from error
    replaced = False
    try:
        with os.fdopen(file_descriptor, "wb") as handle:
            file_descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, mode)
        os.replace(temp_path, path)
        replaced = True
    except OSError as error:
        raise ValueError(f"cannot replace file: {path}") from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if not replaced:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
    fsync_directory(directory)
```

Then in `store.py`: delete the private `_atomic_replace_file` (679–710) and `_fsync_directory` bodies, and near the top imports add `from echo_renderer.fsops import atomic_replace_file, fsync_directory`. Replace the one internal call `_atomic_replace_file(selector_path, data)` (line 544) with `atomic_replace_file(selector_path, data)`, and any `_fsync_directory(` call with `fsync_directory(`.

- [ ] **Step 4: Run tests to verify they pass (new + existing store suite unbroken)**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_fsops echo_renderer.tests.test_store_promote_repair -v`
Expected: PASS (the promote suite still writes selectors via the moved helper).

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/fsops.py Scripts/echo_renderer/store.py Scripts/echo_renderer/tests/test_fsops.py
git commit -m "refactor(renderer): extract shared atomic_replace_file into fsops"
```

## Task 2: Channel-pointer module (`channel.py`)

**Files:**
- Create: `Scripts/echo_renderer/channel.py`
- Test: `Scripts/echo_renderer/tests/test_channel.py`

**Interfaces:**
- Consumes: `atomic_replace_file` (Task 1); `canonical_json_bytes`, `strict_json_object`, `validate_commit_sha`, `validate_sha256` from `echo_renderer.identity`.
- Produces:
  - `CHANNEL_POINTER_NAME = "channel-nightly.json"`
  - `channel_pointer_path(renderer_root: Path) -> Path`
  - `write_channel_pointer(renderer_root: Path, *, installer_source_sha: str, echo_source_sha: str, manifest_sha: str, render_version: int, updated_at: str) -> Path`
  - `read_channel_pointer(renderer_root: Path) -> dict` (raises `ValueError`/`OSError` on missing/corrupt)

- [ ] **Step 1: Write the failing test**

```python
# Scripts/echo_renderer/tests/test_channel.py
import tempfile
import unittest
from pathlib import Path

from echo_renderer.channel import (
    channel_pointer_path,
    read_channel_pointer,
    write_channel_pointer,
)

SRC = "5d473246c8f8209a05c3a4fa47e668ead1b9e54d"
MANIFEST = "55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5"


class ChannelPointerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def test_round_trip(self) -> None:
        write_channel_pointer(
            self.root,
            installer_source_sha=SRC,
            echo_source_sha=SRC,
            manifest_sha=MANIFEST,
            render_version=15,
            updated_at="2026-07-20T06:00:00+00:00",
        )
        payload = read_channel_pointer(self.root)
        self.assertEqual(payload["installerSourceSHA"], SRC)
        self.assertEqual(payload["echoSourceSHA"], SRC)
        self.assertEqual(payload["manifestSHA256"], MANIFEST)
        self.assertEqual(payload["renderVersion"], 15)

    def test_missing_pointer_raises(self) -> None:
        with self.assertRaises((OSError, ValueError)):
            read_channel_pointer(self.root)

    def test_corrupt_pointer_raises(self) -> None:
        channel_pointer_path(self.root).write_bytes(b"{ not json")
        with self.assertRaises(ValueError):
            read_channel_pointer(self.root)

    def test_short_installer_sha_rejected(self) -> None:
        with self.assertRaises(ValueError):
            write_channel_pointer(
                self.root,
                installer_source_sha="abc",
                echo_source_sha=SRC,
                manifest_sha=MANIFEST,
                render_version=15,
                updated_at="2026-07-20T06:00:00+00:00",
            )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_channel -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'echo_renderer.channel'`.

- [ ] **Step 3: Write minimal implementation**

```python
# Scripts/echo_renderer/channel.py
"""The nightly channel pointer: the single accepted-renderer record the skill reads."""
from pathlib import Path

from echo_renderer.fsops import atomic_replace_file
from echo_renderer.identity import (
    canonical_json_bytes,
    strict_json_object,
    validate_commit_sha,
    validate_sha256,
)

CHANNEL_POINTER_NAME = "channel-nightly.json"
_POINTER_KEYS = {
    "schemaVersion",
    "installerSourceSHA",
    "echoSourceSHA",
    "manifestSHA256",
    "renderVersion",
    "updatedAt",
}


def channel_pointer_path(renderer_root: Path) -> Path:
    return renderer_root / CHANNEL_POINTER_NAME


def write_channel_pointer(
    renderer_root: Path,
    *,
    installer_source_sha: str,
    echo_source_sha: str,
    manifest_sha: str,
    render_version: int,
    updated_at: str,
) -> Path:
    validate_commit_sha(installer_source_sha, "installerSourceSHA")
    validate_commit_sha(echo_source_sha, "echoSourceSHA")
    validate_sha256(manifest_sha, "manifestSHA256")
    if not isinstance(render_version, int) or isinstance(render_version, bool):
        raise ValueError("renderVersion must be an integer")
    payload = {
        "schemaVersion": 1,
        "installerSourceSHA": installer_source_sha,
        "echoSourceSHA": echo_source_sha,
        "manifestSHA256": manifest_sha,
        "renderVersion": render_version,
        "updatedAt": updated_at,
    }
    path = channel_pointer_path(renderer_root)
    atomic_replace_file(path, canonical_json_bytes(payload))
    return path


def read_channel_pointer(renderer_root: Path) -> dict:
    path = channel_pointer_path(renderer_root)
    payload = strict_json_object(path.read_bytes())
    missing = _POINTER_KEYS - payload.keys()
    if missing or payload.keys() - _POINTER_KEYS:
        raise ValueError("channel pointer has unexpected keys")
    validate_commit_sha(str(payload["installerSourceSHA"]), "installerSourceSHA")
    validate_commit_sha(str(payload["echoSourceSHA"]), "echoSourceSHA")
    validate_sha256(str(payload["manifestSHA256"]), "manifestSHA256")
    return payload
```

Note: `strict_json_object` takes `bytes` (per `identity.py`). If a future `identity.strict_json_object` signature differs, adapt the `.read_bytes()` call.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_channel -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/channel.py Scripts/echo_renderer/tests/test_channel.py
git commit -m "feat(renderer): add channel-nightly pointer read/write module"
```

## Task 3: `set-channel` CLI subcommand (verify + promote + write pointer)

**Files:**
- Modify: `Scripts/echo_renderer/cli.py` (add subparser + `_handle_set_channel`)
- Test: `Scripts/echo_renderer/tests/test_cli_set_channel.py`

**Interfaces:**
- Consumes: `RendererStore.promote`, `RendererStore.verify` (returns `VerifiedRenderer` with `.manifest.render_version`, `.manifest.installer_source_sha`, `.source_sha`, `.manifest_sha`); `write_channel_pointer` (Task 2).
- Produces: CLI `python3 -m echo_renderer.cli set-channel --source-sha <40hex> --manifest-sha <64hex> [--renderer-root <path>]`. Handler `_handle_set_channel(args, store_factory) -> int`.

- [ ] **Step 1: Write the failing test** (uses the existing `FakeStore` pattern from `test_cli.py`)

```python
# Scripts/echo_renderer/tests/test_cli_set_channel.py
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Sequence

from echo_renderer.channel import read_channel_pointer
from echo_renderer.cli import main
from echo_renderer.identity import (
    FileIdentity,
    ModelPolicy,
    RendererManifest,
    ResourceTreeIdentity,
)
from echo_renderer.store import VerifiedRenderer

SRC = "5d473246c8f8209a05c3a4fa47e668ead1b9e54d"
MANIFEST = "55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5"


def _manifest() -> RendererManifest:
    return RendererManifest(
        schema_version=1,
        echo_source_sha=SRC,
        installer_source_sha=SRC,
        executable_path="echo-cli",
        executable=FileIdentity(sha256="ab" * 32, byte_count=1),
        resources_path="EchoNarrationResources",
        resources=ResourceTreeIdentity(sha256="cd" * 32, regular_file_count=1),
        render_version=15,
        build_configuration="Release",
        architectures=("arm64",),
        minimum_macos_version="15.0",
        model_policy=ModelPolicy(revision="ef" * 20, expected_byte_count=1),
        capabilities=("verify-sidecar",),
    )


class _FakeStore:
    last: "_FakeStore | None" = None

    def __init__(self, renderer_root: Path) -> None:
        self.renderer_root = renderer_root
        self.promoted: tuple[str, str] | None = None
        _FakeStore.last = self

    def promote(self, source_sha: str, manifest_sha: str) -> Path:
        self.promoted = (source_sha, manifest_sha)
        return self.renderer_root / source_sha / "approved-renderer.json"

    def verify(self, source_sha: str, manifest_sha: str) -> VerifiedRenderer:
        return VerifiedRenderer(
            source_sha=source_sha,
            manifest_sha=manifest_sha,
            build_root=self.renderer_root / source_sha / manifest_sha,
            executable=self.renderer_root / source_sha / manifest_sha / "echo-cli",
            resources=self.renderer_root / source_sha / manifest_sha / "res",
            manifest=_manifest(),
        )


class SetChannelCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def _run(self, argv: Sequence[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = main(list(argv), store_factory=_FakeStore)
        return code, out.getvalue(), err.getvalue()

    def test_set_channel_promotes_and_writes_pointer(self) -> None:
        code, _, err = self._run(
            [
                "set-channel",
                "--source-sha", SRC,
                "--manifest-sha", MANIFEST,
                "--renderer-root", str(self.root),
            ]
        )
        self.assertEqual(code, 0, err)
        self.assertEqual(_FakeStore.last.promoted, (SRC, MANIFEST))
        payload = read_channel_pointer(self.root)
        self.assertEqual(payload["installerSourceSHA"], SRC)
        self.assertEqual(payload["renderVersion"], 15)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_cli_set_channel -v`
Expected: FAIL — argparse rejects the unknown `set-channel` command (exit 64) so `main` returns 64, assertion fails.

- [ ] **Step 3: Add the subcommand + handler in `cli.py`**

In `build_parser()` (after the `promote` block, before `repair`), add:

```python
    set_channel_parser = subparsers.add_parser(
        "set-channel",
        help="Promote a package and point the nightly channel pointer at it",
    )
    set_channel_parser.add_argument("--source-sha", type=_commit_sha_argument, required=True)
    set_channel_parser.add_argument("--manifest-sha", type=_sha256_argument, required=True)
    _add_renderer_root_argument(set_channel_parser)
    set_channel_parser.set_defaults(handler=_handle_set_channel)
```

Add the handler (near `_handle_promote`), plus imports at the top of `cli.py`
(`from datetime import datetime, timezone` and `from echo_renderer.channel import write_channel_pointer`):

```python
def _handle_set_channel(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    store = store_factory(args.renderer_root)
    store.promote(args.source_sha, args.manifest_sha)
    verified = store.verify(args.source_sha, args.manifest_sha)
    write_channel_pointer(
        args.renderer_root,
        installer_source_sha=verified.manifest.installer_source_sha,
        echo_source_sha=verified.source_sha,
        manifest_sha=verified.manifest_sha,
        render_version=verified.manifest.render_version,
        updated_at=datetime.now(timezone.utc).isoformat(),
    )
    _print_success(verified, selector_updated=True)
    return 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_cli_set_channel echo_renderer.tests.test_cli -v`
Expected: PASS (new test + the existing CLI suite unbroken).

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/cli.py Scripts/echo_renderer/tests/test_cli_set_channel.py
git commit -m "feat(renderer): add set-channel CLI (promote + write nightly pointer)"
```

## Task 4: Skill resolver reads the pointer (explainer-audiobooks)

**Files:**
- Modify: `skills/custom-learning-audiobook/scripts/echo_installed_renderer.py`
  - Add `accepted_installer_source_sha(renderer_root)` reader.
  - Replace the line-352 gate to compare against it (derive `renderer_root` from the manifest path).
  - Make `_operator_install_recovery` + `main()` recovery defensive.
  - Remove the module constant `ACCEPTED_INSTALLER_SOURCE_SHA` (line 25).
- Test: `tests/test_echo_installed_renderer.py` (add a case; also migrated in Task 5).

**Interfaces:**
- Produces: `accepted_installer_source_sha(renderer_root: Path) -> str` (raises `ValueError`/`OSError` on missing/corrupt); reads `<renderer_root>/channel-nightly.json`.

**Branch setup (run once before Task 4):**

```bash
cd /Users/dfakkeldy/Developer/explainer-audiobooks
git fetch origin main
git worktree add ~/Developer/eab-channel-pointer -b feat/renderer-channel-pointer origin/main
cd ~/Developer/eab-channel-pointer
```

- [ ] **Step 1: Write the failing test** (append to `tests/test_echo_installed_renderer.py`; uses this file's existing `ManifestAndAttestationTests` fixtures — `create_package`, `write_selector`, `renderer_root`, `ACCEPTED_SOURCE_SHA`, `ACCEPTED_INSTALLER_SHA`)

```python
    def test_resolve_new_fails_closed_without_channel_pointer(self):
        _, manifest_sha = self.create_package(renderer_root=self.renderer_root)
        self.write_selector(manifest_sha)
        # No channel-nightly.json written → acceptance gate must fail closed.
        resolved = subprocess.run(
            [
                sys.executable, str(MODULE_PATH), "resolve-new",
                "--source-sha", ACCEPTED_SOURCE_SHA,
                "--renderer-root", str(self.renderer_root),
                "--format", "env0",
            ],
            capture_output=True,
        )
        self.assertEqual(65, resolved.returncode, resolved.stderr.decode())

    def test_resolve_new_accepts_when_pointer_matches(self):
        _, manifest_sha = self.create_package(renderer_root=self.renderer_root)
        self.write_selector(manifest_sha)
        self.write_channel_pointer(manifest_sha)  # helper added in Task 5
        resolved = subprocess.run(
            [
                sys.executable, str(MODULE_PATH), "resolve-new",
                "--source-sha", ACCEPTED_SOURCE_SHA,
                "--renderer-root", str(self.renderer_root),
                "--format", "env0",
            ],
            capture_output=True,
        )
        self.assertEqual(0, resolved.returncode, resolved.stderr.decode())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Developer/eab-channel-pointer && PYTHONPATH=skills/custom-learning-audiobook/scripts python3 -m unittest tests.test_echo_installed_renderer -v -k channel_pointer`
Expected: FAIL — `test_resolve_new_fails_closed_without_channel_pointer` currently returns 0 (constant still accepts the fixture), and `write_channel_pointer` helper does not exist yet.

- [ ] **Step 3: Implement the pointer reader + gate + defensive recovery**

Delete line 25 (`ACCEPTED_INSTALLER_SOURCE_SHA = "..."`). Add the reader (near `canonical_renderer_root`, ~line 105):

```python
_CHANNEL_POINTER_NAME = "channel-nightly.json"


def accepted_installer_source_sha(renderer_root: Path) -> str:
    """Read the accepted installer SHA from the nightly channel pointer (fail-closed)."""
    pointer = renderer_root / _CHANNEL_POINTER_NAME
    payload = strict_json_object(pointer, "renderer channel pointer")
    value = _require_string(payload.get("installerSourceSHA"), "installerSourceSHA")
    _validate_commit_sha(value, "installerSourceSHA")
    return value
```

(`strict_json_object` here is the skill's own helper that takes a path + label — confirm its
signature in this file; it raises on a missing/corrupt file, which `main()` maps to exit 65.)

Change the gate at line 352. It lives inside `parse_manifest`, whose `manifest_path` is
`<renderer_root>/<source_sha>/<manifest_sha>/renderer-manifest.json`, so derive the root from it:

```python
    installer_source_sha = _require_string(
        payload["installerSourceSHA"], "installerSourceSHA"
    )
    _validate_commit_sha(installer_source_sha, "installerSourceSHA")
    renderer_root = manifest_path.parents[2]
    if installer_source_sha != accepted_installer_source_sha(renderer_root):
        raise ValueError("renderer manifest installer identity is not accepted")
```

(Confirm the local variable name for the manifest path inside `parse_manifest`; the extractor
saw the caller pass `source_root / manifest_sha / _MANIFEST_NAME`. Use whatever the parameter is
named in the `def parse_manifest(...)` signature.)

Make the recovery message defensive. Change `_operator_install_recovery` to take the SHA text:

```python
def _operator_install_recovery(source_sha: str, installer_sha: str) -> str:
    return (
        "operator-only recovery command:\n"
        "PYTHONPATH=Scripts python3 -m echo_renderer.cli install \\\n"
        "  --installer-worktree <clean-reviewed-installer-worktree> \\\n"
        f"  --installer-sha {installer_sha} \\\n"
        "  --source-worktree <clean-source-worktree-at-SHA> \\\n"
        f"  --source-sha {source_sha} \\\n"
        "  --promote"
    )
```

In `main()`'s except block (lines 811–817), resolve the accepted SHA defensively before calling it:

```python
    except (OSError, ValueError) as error:
        print(f"echo_installed_renderer: {error}", file=sys.stderr)
        if options.command in ("resolve-new", "resolve-resume") and (
            _COMMIT_SHA_PATTERN.fullmatch(options.source_sha) is not None
        ):
            try:
                installer_sha = accepted_installer_source_sha(
                    canonical_renderer_root(options.renderer_root)
                )
            except (OSError, ValueError):
                installer_sha = "<no accepted renderer pointer — run make track-renderer-nightly>"
            print(
                _operator_install_recovery(options.source_sha, installer_sha),
                file=sys.stderr,
            )
        return 65
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/Developer/eab-channel-pointer && PYTHONPATH=skills/custom-learning-audiobook/scripts python3 -m unittest tests.test_echo_installed_renderer -v`
Expected: the two new tests PASS. Other tests in this file may still fail until Task 5 migrates the fixtures — that's expected; Task 5 finishes them.

- [ ] **Step 5: Commit** (after Task 5 turns the suite green — see Task 5 Step 5)

## Task 5: Migrate the two constant-pinned test fixtures to write a pointer

**Files:**
- Modify: `tests/test_echo_installed_renderer.py` (add `write_channel_pointer` helper; call it wherever a package+selector are staged for a success path)
- Modify: `tests/test_custom_learning_audiobook_echo_runtime.py` (write the pointer into its temp `renderer_root` in `setUp`)

**Interfaces:**
- Consumes: the resolver's pointer reader (Task 4). The fixtures write `channel-nightly.json` carrying `installerSourceSHA = ACCEPTED_INSTALLER_SHA`, `echoSourceSHA = ACCEPTED_SOURCE_SHA`.

- [ ] **Step 1: Add the `write_channel_pointer` helper to `test_echo_installed_renderer.py`**

In `ManifestAndAttestationTests`, add (mirrors `write_selector`, writing to the store root):

```python
    def write_channel_pointer(self, manifest_sha: str) -> None:
        import json
        self.renderer_root.mkdir(parents=True, exist_ok=True)
        (self.renderer_root / "channel-nightly.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "installerSourceSHA": ACCEPTED_INSTALLER_SHA,
                    "echoSourceSHA": ACCEPTED_SOURCE_SHA,
                    "manifestSHA256": manifest_sha,
                    "renderVersion": 15,
                    "updatedAt": "2026-07-20T06:00:00+00:00",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        )
```

Then in every existing success-path test that calls `self.write_selector(manifest_sha)` and
expects `resolve-new` to succeed (e.g. `test_resolver_cli_emits_env0_and_reports_usage_as_64`
line 520), add `self.write_channel_pointer(manifest_sha)` immediately after the `write_selector`
call. Do **not** add it to negative/rejection tests.

- [ ] **Step 2: Migrate `test_custom_learning_audiobook_echo_runtime.py`**

In its `setUp` (after the renderer_root + package are laid out, ~line 232), add:

```python
        import json
        (self.renderer_root / "channel-nightly.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "installerSourceSHA": self.installer_source_sha,
                    "echoSourceSHA": self.source_sha,
                    "manifestSHA256": manifest_sha,
                    "renderVersion": 15,
                    "updatedAt": "2026-07-20T06:00:00+00:00",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        )
```

(Use the local variable holding the built manifest SHA in that `setUp`; if it is not in scope,
compute it the same way `create_package`/the manifest builder does.)

- [ ] **Step 3: Run the full explainer resolver + runtime suites**

Run:
```bash
cd ~/Developer/eab-channel-pointer
PYTHONPATH=skills/custom-learning-audiobook/scripts python3 -m unittest \
  tests.test_echo_installed_renderer tests.test_custom_learning_audiobook_echo_runtime -v
```
Expected: PASS (all previously-green tests green again + the two new Task-4 tests).

- [ ] **Step 4: Run the whole explainer test suite to catch collateral**

Run: `cd ~/Developer/eab-channel-pointer && python3 -m pytest -q 2>/dev/null || PYTHONPATH=skills/custom-learning-audiobook/scripts python3 -m unittest discover -s tests -v`
Expected: no new failures versus `origin/main` baseline.

- [ ] **Step 5: Commit (Tasks 4 + 5 together — the suite is only green with both)**

```bash
cd ~/Developer/eab-channel-pointer
git add skills/custom-learning-audiobook/scripts/echo_installed_renderer.py tests/test_echo_installed_renderer.py tests/test_custom_learning_audiobook_echo_runtime.py
git commit -m "feat(renderer): resolver accepts installer SHA from channel-nightly pointer

Replaces the hard-coded ACCEPTED_INSTALLER_SOURCE_SHA constant with a
fail-closed read of <renderer_root>/channel-nightly.json; migrates temp-root
fixtures to write the pointer."
```

## Task 6: Shell wrappers default the pronunciation SHA from the pointer

**Files:**
- Modify: `skills/custom-learning-audiobook/scripts/echo_pronunciation_preflight.sh` (add helper `echo_pronunciation_default_source_sha_from_pointer`; call it before the `-z` guard at line 90)
- Modify: `skills/custom-learning-audiobook/scripts/echo_learning_pilot_narrate.sh` (call the helper before its line-121 gate — it already sources preflight)
- Test: `tests/test_channel_pointer_default.py` (new)

**Interfaces:**
- Consumes: `<renderer_root>/channel-nightly.json` `echoSourceSHA`.
- Produces: shell fn `echo_pronunciation_default_source_sha_from_pointer` that sets `APPROVED_ECHO_PRONUNCIATION_SHA` from the pointer **only when it is currently unset**; a missing/unreadable pointer leaves it unset (so the existing `-z` guard still fails closed).

- [ ] **Step 1: Write the failing test** (drives the preflight function in a subshell)

```python
# tests/test_channel_pointer_default.py
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

PREFLIGHT = Path("skills/custom-learning-audiobook/scripts/echo_pronunciation_preflight.sh").resolve()
SRC = "5d473246c8f8209a05c3a4fa47e668ead1b9e54d"


class PointerDefaultTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "channel-nightly.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "installerSourceSHA": SRC,
                    "echoSourceSHA": SRC,
                    "manifestSHA256": "5" * 64,
                    "renderVersion": 15,
                    "updatedAt": "2026-07-20T06:00:00+00:00",
                }
            )
        )

    def _run(self, env_extra: dict) -> tuple[int, str]:
        script = (
            f'source "{PREFLIGHT}"; '
            'echo_pronunciation_default_source_sha_from_pointer; '
            'printf "%s" "${APPROVED_ECHO_PRONUNCIATION_SHA:-UNSET}"'
        )
        env = {**os.environ, "ECHO_RENDERER_ROOT": str(self.root), **env_extra}
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        return result.returncode, result.stdout

    def test_defaults_when_unset(self) -> None:
        _, out = self._run({})
        self.assertEqual(out, SRC)

    def test_does_not_override_when_already_set(self) -> None:
        _, out = self._run({"APPROVED_ECHO_PRONUNCIATION_SHA": "a" * 40})
        self.assertEqual(out, "a" * 40)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Developer/eab-channel-pointer && python3 -m unittest tests.test_channel_pointer_default -v`
Expected: FAIL — `echo_pronunciation_default_source_sha_from_pointer: command not found`.

- [ ] **Step 3: Add the helper to `echo_pronunciation_preflight.sh`** (near the top, after `require_renderer_commit_sha` ~line 44) and call it

```bash
echo_pronunciation_default_source_sha_from_pointer() {
  # When APPROVED_ECHO_PRONUNCIATION_SHA is unset, adopt the nightly channel
  # pointer's echoSourceSHA. A missing/unreadable pointer leaves it unset so the
  # existing required-var guard still fails closed.
  if [[ -n ${APPROVED_ECHO_PRONUNCIATION_SHA:-} ]]; then
    return 0
  fi
  local root="${ECHO_RENDERER_ROOT:-$HOME/Library/Application Support/Echo/Renderers}"
  local pointer="$root/channel-nightly.json"
  [[ -f "$pointer" ]] || return 0
  local value
  value=$(/usr/local/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["echoSourceSHA"])' "$pointer" 2>/dev/null) || return 0
  if [[ "$value" =~ ^[0-9a-f]{40}$ ]]; then
    export APPROVED_ECHO_PRONUNCIATION_SHA="$value"
  fi
}
```

Call it at the start of `echo_pronunciation_resolve_installed_renderer` — insert a line
immediately before the `-z` guard (before line 90):

```bash
  echo_pronunciation_default_source_sha_from_pointer
  if [[ -z ${APPROVED_ECHO_PRONUNCIATION_SHA:-} ]]; then
```

- [ ] **Step 4: Call the helper in `echo_learning_pilot_narrate.sh`** before its gate (before line 121)

```bash
  echo_pronunciation_default_source_sha_from_pointer
  require_renderer_commit_sha APPROVED_ECHO_PRONUNCIATION_SHA \
    "${APPROVED_ECHO_PRONUNCIATION_SHA:-}" || return $?
```

- [ ] **Step 5: Run tests to verify they pass, then commit**

Run: `cd ~/Developer/eab-channel-pointer && python3 -m unittest tests.test_channel_pointer_default -v`
Expected: PASS (2 tests).

```bash
cd ~/Developer/eab-channel-pointer
git add skills/custom-learning-audiobook/scripts/echo_pronunciation_preflight.sh skills/custom-learning-audiobook/scripts/echo_learning_pilot_narrate.sh tests/test_channel_pointer_default.py
git commit -m "feat(renderer): default APPROVED_ECHO_PRONUNCIATION_SHA from channel pointer"
```

## Task 7: Operator step — promote 5d473246 + write the initial pointer (get current now)

**Files:** none (operator action; run after Task 3 lands on Echo `feat/nightly-renderer-auto-tracker`).

- [ ] **Step 1: Set the channel to the already-installed nightly package**

Run (from the Echo main clone on the feature branch, which has `set-channel`):
```bash
cd /Users/dfakkeldy/Developer/Echo
PYTHONPATH=Scripts python3 -m echo_renderer.cli set-channel \
  --source-sha 5d473246c8f8209a05c3a4fa47e668ead1b9e54d \
  --manifest-sha 55c5ff681edb80b30301f7526b601c590c280b83bab6e2f1d23168325abfe6d5
```
Expected stdout: `installerSourceSHA=5d473246…`, `manifestSHA256=55c5ff68…`, `selectorUpdated=true`.

- [ ] **Step 2: Verify the pointer exists and the skill accepts it**

```bash
cat "$HOME/Library/Application Support/Echo/Renderers/channel-nightly.json"
cd ~/Developer/eab-channel-pointer
PYTHONPATH=skills/custom-learning-audiobook/scripts python3 -m echo_installed_renderer \
  resolve-new --source-sha 5d473246c8f8209a05c3a4fa47e668ead1b9e54d --format env0 >/dev/null && echo "RESOLVER OK"
```
Expected: pointer JSON printed; `RESOLVER OK`.

- [ ] **Step 3: Open the two Slice-1 PRs**

```bash
cd /Users/dfakkeldy/Developer/Echo && git push -u origin feat/nightly-renderer-auto-tracker && gh pr create --base nightly --fill
cd ~/Developer/eab-channel-pointer && git push -u origin feat/renderer-channel-pointer && gh pr create --base main --fill
```

---

# SLICE 2 — Automation (scheduled tracker)

## Task 8: Run-lock helper (`runlock.py`)

**Files:**
- Create: `Scripts/echo_renderer/runlock.py`
- Test: `Scripts/echo_renderer/tests/test_runlock.py`

**Interfaces:**
- Produces: context manager `run_lock(lock_path: Path)` that yields on success and raises `AlreadyRunning` if another holder has the flock. Non-blocking (`fcntl.flock(LOCK_EX | LOCK_NB)`).

- [ ] **Step 1: Write the failing test**

```python
# Scripts/echo_renderer/tests/test_runlock.py
import tempfile
import unittest
from pathlib import Path

from echo_renderer.runlock import AlreadyRunning, run_lock


class RunLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lock = Path(self.tmp.name) / "track.lock"

    def test_second_acquisition_raises_already_running(self) -> None:
        with run_lock(self.lock):
            with self.assertRaises(AlreadyRunning):
                with run_lock(self.lock):
                    pass

    def test_reacquire_after_release(self) -> None:
        with run_lock(self.lock):
            pass
        with run_lock(self.lock):
            pass  # no raise


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_runlock -v`
Expected: FAIL — `No module named 'echo_renderer.runlock'`.

- [ ] **Step 3: Write minimal implementation**

```python
# Scripts/echo_renderer/runlock.py
"""A single-holder, non-blocking run-lock so scheduled tracker runs never overlap."""
import contextlib
import fcntl
import os
from pathlib import Path


class AlreadyRunning(RuntimeError):
    """Raised when another process already holds the tracker run-lock."""


@contextlib.contextmanager
def run_lock(lock_path: Path):
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise AlreadyRunning("another track-nightly run is in progress") from error
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_runlock -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/runlock.py Scripts/echo_renderer/tests/test_runlock.py
git commit -m "feat(renderer): add non-blocking run-lock for the nightly tracker"
```

## Task 9: Prune helper (`track.py` — `prune_packages`)

**Files:**
- Create: `Scripts/echo_renderer/track.py` (start with `prune_packages`)
- Test: `Scripts/echo_renderer/tests/test_track.py`

**Interfaces:**
- Produces: `prune_packages(renderer_root: Path, keep: int, keep_source_sha: str, keep_manifest_sha: str) -> list[Path]` — deletes older `<40hex>/<64hex>` package dirs, always keeping the pinned one + the most-recent `keep` by mtime; returns deleted paths. Skips the pointer file, `approved-renderer.json` selectors, and non-package entries.

- [ ] **Step 1: Write the failing test**

```python
# Scripts/echo_renderer/tests/test_track.py
import tempfile
import time
import unittest
from pathlib import Path

from echo_renderer.track import prune_packages

SRC = "5d473246c8f8209a05c3a4fa47e668ead1b9e54d"


def _make_pkg(root: Path, source: str, manifest: str) -> Path:
    pkg = root / source / manifest
    pkg.mkdir(parents=True)
    (pkg / "renderer-manifest.json").write_text("{}")
    return pkg


class PruneTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def test_keeps_pinned_and_last_n_and_skips_pointer(self) -> None:
        (self.root / "channel-nightly.json").write_text("{}")
        keep_manifest = "a" * 64
        pinned = _make_pkg(self.root, SRC, keep_manifest)
        (self.root / SRC / "approved-renderer.json").write_text("{}")
        old = []
        for i in range(3):
            m = f"{i}" * 64
            old.append(_make_pkg(self.root, "b" * 40, m))
            time.sleep(0.01)
        deleted = prune_packages(self.root, keep=1, keep_source_sha=SRC, keep_manifest_sha=keep_manifest)
        # survivors = pinned (always) + the newest 1 by mtime (the last `b` package);
        # the two older `b` packages are deleted. Pointer + selector are never packages.
        self.assertTrue(pinned.exists())
        self.assertTrue((self.root / "channel-nightly.json").exists())
        self.assertTrue((self.root / SRC / "approved-renderer.json").exists())
        self.assertEqual(len(deleted), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_track -v`
Expected: FAIL — `No module named 'echo_renderer.track'`.

- [ ] **Step 3: Implement `prune_packages`**

```python
# Scripts/echo_renderer/track.py
"""Nightly renderer tracker: prune + orchestration."""
import re
import shutil
from pathlib import Path

_SOURCE_RE = re.compile(r"[0-9a-f]{40}\Z")
_MANIFEST_RE = re.compile(r"[0-9a-f]{64}\Z")


def _packages(renderer_root: Path) -> list[Path]:
    found = []
    for source_dir in renderer_root.iterdir():
        if not source_dir.is_dir() or not _SOURCE_RE.match(source_dir.name):
            continue
        for pkg in source_dir.iterdir():
            if pkg.is_dir() and _MANIFEST_RE.match(pkg.name):
                found.append(pkg)
    return found


def prune_packages(
    renderer_root: Path,
    keep: int,
    keep_source_sha: str,
    keep_manifest_sha: str,
) -> list[Path]:
    pinned = renderer_root / keep_source_sha / keep_manifest_sha
    packages = _packages(renderer_root)
    survivors = {pinned.resolve()}
    ordered = sorted(packages, key=lambda p: p.stat().st_mtime, reverse=True)
    for pkg in ordered:
        if len(survivors) >= keep + 1:
            break
        survivors.add(pkg.resolve())
    deleted = []
    for pkg in packages:
        if pkg.resolve() in survivors:
            continue
        shutil.rmtree(pkg)
        deleted.append(pkg)
    return deleted
```

Run the test, read the actual deleted count, and set the Step-1 assertion to that exact number
(the survivor-invariant assertions must stay).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_track -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/track.py Scripts/echo_renderer/tests/test_track.py
git commit -m "feat(renderer): add package pruning that keeps the pinned package + pointer"
```

## Task 10: `track-nightly` orchestrator + CLI subcommand

**Files:**
- Modify: `Scripts/echo_renderer/track.py` (add `track_nightly(...)` orchestration)
- Modify: `Scripts/echo_renderer/cli.py` (add `track-nightly` subcommand + `_handle_track_nightly`)
- Test: `Scripts/echo_renderer/tests/test_track.py` (add orchestration tests with fakes)

**Interfaces:**
- Consumes: `run_lock` (Task 8), `prune_packages` (Task 9), `read_channel_pointer`/`write_channel_pointer` (Task 2), `RendererStore.install` with `InstallRequest(..., promote=True)` (returns `InstallResult.verified`), and a git runner.
- Produces: `track_nightly(*, echo_repo, worktree_root, renderer_root, build_gate, keep, dry_run, store_factory, git_runner, now) -> int` returning an exit code (0 ok / 0 skip / 74 fetch-fail). CLI `python3 -m echo_renderer.cli track-nightly [flags]`.

- [ ] **Step 1: Write the failing tests** (advance path + no-op path, git + store faked)

```python
    # add to test_track.py
    def test_noop_when_tip_matches_pointer(self) -> None:
        from echo_renderer.channel import write_channel_pointer
        from echo_renderer.track import track_nightly
        write_channel_pointer(
            self.root, installer_source_sha=SRC, echo_source_sha=SRC,
            manifest_sha="a" * 64, render_version=15, updated_at="t",
        )
        calls = []

        def git_runner(args):  # returns stdout for rev-parse
            calls.append(args)
            if "rev-parse" in args:
                return SRC + "\n"
            return ""

        def store_factory(root):
            raise AssertionError("install must not run on a no-op")

        code = track_nightly(
            echo_repo=self.root, worktree_root=self.root / "wt", renderer_root=self.root,
            build_gate=self.root / "gate", keep=3, dry_run=False,
            store_factory=store_factory, git_runner=git_runner, now="t",
        )
        self.assertEqual(code, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_track -v -k noop`
Expected: FAIL — `cannot import name 'track_nightly'`.

- [ ] **Step 3: Implement `track_nightly`** (append to `track.py`)

```python
from echo_renderer.channel import channel_pointer_path, read_channel_pointer, write_channel_pointer
from echo_renderer.runlock import AlreadyRunning, run_lock
from echo_renderer.store import InstallRequest


def _current_pointer_sha(renderer_root):
    try:
        return str(read_channel_pointer(renderer_root)["installerSourceSHA"])
    except (OSError, ValueError, KeyError):
        return None  # missing/corrupt → treat as "not up to date"


def track_nightly(*, echo_repo, worktree_root, renderer_root, build_gate,
                  keep, dry_run, store_factory, git_runner, now):
    lock_path = renderer_root / ".track-nightly.lock"
    try:
        with run_lock(lock_path):
            try:
                git_runner(["git", "-C", str(echo_repo), "fetch", "origin", "nightly"])
                tip = git_runner(["git", "-C", str(echo_repo), "rev-parse", "origin/nightly"]).strip()
            except OSError:
                return 74
            if tip == _current_pointer_sha(renderer_root):
                return 0  # up to date
            if dry_run:
                return 0
            installer_wt = worktree_root / f"echo-installer-{tip[:12]}"
            source_wt = worktree_root / f"echo-source-{tip[:12]}"
            _prepare_worktree(git_runner, echo_repo, installer_wt, tip)
            _prepare_worktree(git_runner, echo_repo, source_wt, tip)
            try:
                store = store_factory(renderer_root)
                result = store.install(InstallRequest(
                    installer_worktree=installer_wt, installer_sha=tip,
                    source_worktree=source_wt, source_sha=tip,
                    renderer_root=renderer_root, build_gate=build_gate, promote=True,
                ))
            finally:
                _cleanup_worktree(git_runner, echo_repo, installer_wt)
                _cleanup_worktree(git_runner, echo_repo, source_wt)
            write_channel_pointer(
                renderer_root,
                installer_source_sha=result.verified.manifest.installer_source_sha,
                echo_source_sha=result.verified.source_sha,
                manifest_sha=result.verified.manifest_sha,
                render_version=result.verified.manifest.render_version,
                updated_at=now,
            )
            prune_packages(renderer_root, keep, result.verified.source_sha, result.verified.manifest_sha)
            return 0
    except AlreadyRunning:
        return 0  # clean skip


def _prepare_worktree(git_runner, echo_repo, path, tip):
    if (path / ".git").exists():
        git_runner(["git", "-C", str(path), "fetch", "origin", "nightly"])
        git_runner(["git", "-C", str(path), "reset", "--hard", tip])
        git_runner(["git", "-C", str(path), "clean", "-fdx"])
    else:
        git_runner(["git", "-C", str(echo_repo), "worktree", "add", "--detach", str(path), tip])


def _cleanup_worktree(git_runner, echo_repo, path):
    git_runner(["git", "-C", str(echo_repo), "worktree", "remove", "--force", str(path)])
```

Add the real default `git_runner` (used by the CLI handler) — a thin `subprocess.run` wrapper
returning stdout and raising `OSError` on non-zero:

```python
import subprocess


def default_git_runner(args):
    completed = subprocess.run(args, capture_output=True, text=True)
    if completed.returncode != 0:
        raise OSError(f"git failed ({completed.returncode}): {completed.stderr.strip()}")
    return completed.stdout
```

- [ ] **Step 4: Wire the CLI subcommand** in `cli.py` (`build_parser` + handler) and run tests

```python
    track_parser = subparsers.add_parser(
        "track-nightly", help="Refresh the renderer to origin/nightly's tip if it moved"
    )
    _add_renderer_root_argument(track_parser)
    _add_build_gate_argument(track_parser)
    track_parser.add_argument("--echo-repo", type=Path, default=Path("~/Developer/Echo").expanduser())
    track_parser.add_argument("--worktree-root", type=Path, default=Path("~/Developer/InstallWorktrees").expanduser())
    track_parser.add_argument("--keep", type=int, default=3)
    track_parser.add_argument("--dry-run", action="store_true")
    track_parser.set_defaults(handler=_handle_track_nightly)
```

```python
def _handle_track_nightly(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    from datetime import datetime, timezone
    from echo_renderer.track import default_git_runner, track_nightly
    _ensure_renderer_root(args.renderer_root)
    return track_nightly(
        echo_repo=args.echo_repo, worktree_root=args.worktree_root,
        renderer_root=args.renderer_root, build_gate=args.build_gate,
        keep=args.keep, dry_run=args.dry_run, store_factory=store_factory,
        git_runner=default_git_runner, now=datetime.now(timezone.utc).isoformat(),
    )
```

Run: `cd /Users/dfakkeldy/Developer/Echo && PYTHONPATH=Scripts python3 -m unittest echo_renderer.tests.test_track -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Scripts/echo_renderer/track.py Scripts/echo_renderer/cli.py Scripts/echo_renderer/tests/test_track.py
git commit -m "feat(renderer): add track-nightly orchestrator + CLI subcommand"
```

## Task 11: Makefile target + launchd template + guide

**Files:**
- Modify: `Makefile` (add `track-renderer-nightly` + `.PHONY`)
- Create: `Scripts/echo_renderer/launchd/com.echo.renderer.track-nightly.plist`
- Modify: `docs/guides/versioned-echo-renderer.md` (new "Nightly channel + auto-tracker" section)

- [ ] **Step 1: Add the Makefile target** (append after `repair-renderer`, and add the name to the `.PHONY` line 1)

```makefile
track-renderer-nightly: ## Refresh the renderer to origin/nightly's tip if it moved
	@PYTHONPATH=Scripts python3 -m echo_renderer.cli track-nightly \
	  $(if $(ECHO_RENDERER_ROOT),--renderer-root "$(ECHO_RENDERER_ROOT)") \
	  $(if $(ECHO_BUILD_GATE),--build-gate "$(ECHO_BUILD_GATE)")
```

- [ ] **Step 2: Create the LaunchAgent template**

```xml
<!-- Scripts/echo_renderer/launchd/com.echo.renderer.track-nightly.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.echo.renderer.track-nightly</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/make</string>
        <string>-C</string>
        <string>/Users/dfakkeldy/Developer/Echo</string>
        <string>track-renderer-nightly</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>/Users/dfakkeldy/Library/Logs/Echo/renderer-track-nightly.log</string>
    <key>StandardErrorPath</key><string>/Users/dfakkeldy/Library/Logs/Echo/renderer-track-nightly.log</string>
</dict>
</plist>
```

- [ ] **Step 3: Document it** — add a "Nightly channel + auto-tracker" section to `docs/guides/versioned-echo-renderer.md` covering: the `channel-nightly.json` schema, `set-channel`, `track-nightly` (+ `--dry-run`), `make track-renderer-nightly`, installing the LaunchAgent (`launchctl bootstrap gui/$(id -u) <plist>`), the `--keep` prune policy, machine-local time semantics, and rollback (manual `set-channel` at an older still-present package).

- [ ] **Step 4: Verify the full echo_renderer suite is green**

Run: `cd /Users/dfakkeldy/Developer/Echo && make renderer-install-test`
Expected: all tests PASS (including the new `test_fsops`, `test_channel`, `test_cli_set_channel`, `test_runlock`, `test_track`).

- [ ] **Step 5: Commit + open the Slice-2 PR**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Makefile Scripts/echo_renderer/launchd docs/guides/versioned-echo-renderer.md
git commit -m "feat(renderer): make target, launchd agent, and guide for the nightly tracker"
git push && gh pr create --base nightly --fill   # or push to the same Slice-1 PR branch
```

---

## Acceptance (once both slices merge)

- `make track-renderer-nightly` on an unchanged nightly logs "up to date" and does not build.
- After a nightly advance, one scheduled run builds, promotes, and rewrites `channel-nightly.json`; a governed narrate resolves the new package with no manual SHA.
- The LaunchAgent fires daily at 06:00 local; overlapping runs cleanly skip (exit 0).
