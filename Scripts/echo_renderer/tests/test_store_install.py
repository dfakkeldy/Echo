from __future__ import annotations

import os
import platform
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import echo_renderer.store as store_module
from echo_renderer.git_state import ApprovedWorktree
from echo_renderer.lease import TEMPORARY_FAILURE, LeaseSet, canonical_lease_root
from echo_renderer.store import (
    InstallRequest,
    InstallResult,
    RendererStore,
)


REQUIRED_NARRATE_CAPABILITIES = (
    "--cover",
    "--sidecar",
    "--voice",
    "--db",
    "--work-dir",
    "--jobs",
    "--threads",
    "--resume",
    "--max-chapters",
    "--no-pronunciation-review",
)
REQUIRED_CAPABILITIES = REQUIRED_NARRATE_CAPABILITIES + ("verify-sidecar",)
GIT = "/usr/bin/git"
MAKE = "/usr/bin/make"
MODEL_REVISION = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"


class InstallRunner:
    """Fakes the build gate, ``make echo-cli``, and the release CLI probes.

    ``make`` materializes deterministic fixture build output on disk (as the
    real Xcode build would) so the rest of the installation transaction
    exercises real filesystem behavior. Only the external processes are
    faked; every copy, hash, lease, and manifest write in the code under
    test runs for real.
    """

    def __init__(
        self,
        *,
        source_worktree: Path,
        build_gate: Path,
        version: str = "ONNX rv15 (Release)\n",
        capabilities: tuple[str, ...] = REQUIRED_NARRATE_CAPABILITIES,
        architectures: tuple[str, ...] = (platform.machine(),),
        minimum_macos_version: str = "15.0",
    ) -> None:
        self.source_worktree = source_worktree
        self.build_gate = build_gate
        self.version = version
        self.capabilities = capabilities
        self.architectures = architectures
        self.minimum_macos_version = minimum_macos_version
        self.executable_bytes = b"Mach-O fixture bytes\n"
        self.resources: dict[str, bytes] = {
            "voices/default.json": b'{"voice":"am_michael"}\n',
            "phonemes.txt": b"fixture phonemes\n",
        }
        self.gate_should_fail = False
        self.make_should_fail = False
        self.gate_calls = 0
        self.make_calls = 0
        self.drop_staged_resource: str | None = None
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []
        self.events: list[tuple[str, ...]] | None = None

    def _record(self, kind: str) -> None:
        if self.events is not None:
            self.events.append(("runner", kind))

    def build_products_root(self) -> Path:
        return self.source_worktree / ".build" / "cli" / "Build" / "Products" / "Release"

    def materialize_build_output(self) -> None:
        products = self.build_products_root()
        products.mkdir(parents=True, exist_ok=True)
        executable = products / "echo-cli"
        executable.write_bytes(self.executable_bytes)
        executable.chmod(0o755)
        resources_root = products / "EchoNarrationResources"
        resources_root.mkdir(exist_ok=True)
        for relative_path, data in self.resources.items():
            destination = resources_root.joinpath(*relative_path.split("/"))
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)

    def __call__(
        self, arguments: list[str], **keywords: object
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append((tuple(arguments), dict(keywords)))

        if list(arguments) == [str(self.build_gate), "--wait"]:
            self.gate_calls += 1
            self._record("gate")
            returncode = 1 if self.gate_should_fail else 0
            return subprocess.CompletedProcess(arguments, returncode, stdout="", stderr="")

        if list(arguments) == [MAKE, "-C", str(self.source_worktree), "echo-cli"]:
            self.make_calls += 1
            self._record("make")
            if self.make_should_fail:
                return subprocess.CompletedProcess(
                    arguments, 1, stdout="", stderr="make failed\n"
                )
            self.materialize_build_output()
            return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")

        if arguments[0] == "/usr/bin/lipo":
            self._record("lipo")
            stdout = " ".join(self.architectures) + "\n"
        elif arguments[0] == "/usr/bin/otool":
            self._record("otool")
            stdout = (
                "Load command 10\n"
                "      cmd LC_BUILD_VERSION\n"
                "  cmdsize 32\n"
                " platform 1\n"
                f"    minos {self.minimum_macos_version}\n"
                "      sdk 26.0\n"
            )
        elif arguments[1:] == ["--version"]:
            self._record("version")
            probed_executable = Path(arguments[0])
            if not probed_executable.is_file():
                raise AssertionError(
                    "install() probed the CLI before it was staged: "
                    f"{probed_executable}"
                )
            if self.drop_staged_resource is not None:
                staged_resources = Path(str(keywords["env"]["ECHO_RESOURCE_DIR"]))
                dropped = staged_resources.joinpath(*self.drop_staged_resource.split("/"))
                if dropped.exists():
                    dropped.unlink()
            stdout = self.version
        elif arguments[1:] == ["narrate", "--help"]:
            self._record("narrate-help")
            stdout = "USAGE: echo-cli narrate " + " ".join(self.capabilities) + "\n"
        elif arguments[1:] == ["verify-sidecar", "--help"]:
            self._record("verify-sidecar-help")
            stdout = (
                "USAGE: echo-cli verify-sidecar --epub <epub> --audio <audio> "
                "--sidecar <sidecar>\n"
            )
        else:
            raise AssertionError(f"unexpected install runner arguments: {arguments!r}")
        return subprocess.CompletedProcess(arguments, 0, stdout=stdout, stderr="")


class InstallFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

        self.renderer_root = (self.root / "renderers").resolve()
        self.renderer_root.mkdir()

        self.installer_worktree = (self.root / "installer-worktree").resolve()
        self.installer_worktree.mkdir()
        self.installer_sha = self._init_repo(
            self.installer_worktree, {"installer.txt": "installer fixture v1\n"}
        )

        self.source_worktree = (self.root / "source-worktree").resolve()
        self.source_worktree.mkdir()
        self.source_sha = self._init_repo(
            self.source_worktree,
            {
                ".gitignore": ".build/\n",
                "EchoCore/Services/Narration/OnnxKokoroEngine.swift": (
                    "private nonisolated static let modelRevision = "
                    f'"{MODEL_REVISION}"\n'
                    "nonisolated static let expectedModelBytes = 163_234_740\n"
                ),
            },
        )

        self.build_gate = self.installer_worktree / "fake-build-gate.sh"
        self.runner = InstallRunner(
            source_worktree=self.source_worktree, build_gate=self.build_gate
        )
        self.store = RendererStore(self.renderer_root, runner=self.runner)

    def _git(self, root: Path, *arguments: str) -> str:
        completed = subprocess.run(
            [GIT, *arguments],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout

    def _init_repo(self, root: Path, files: dict[str, str]) -> str:
        self._git(root, "init", "--quiet")
        self._git(root, "config", "user.name", "Renderer Install Tests")
        self._git(root, "config", "user.email", "renderer-install-tests@example.invalid")
        for relative_path, content in files.items():
            self._write_and_add(root, relative_path, content)
        self._git(root, "commit", "--quiet", "-m", "initial commit")
        return self._git(root, "rev-parse", "HEAD").strip()

    def _write_and_add(self, root: Path, relative_path: str, content: str) -> None:
        destination = root.joinpath(*relative_path.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        self._git(root, "add", relative_path)

    def _recommit_installer(self, content: str) -> str:
        self._write_and_add(self.installer_worktree, "installer.txt", content)
        self._git(self.installer_worktree, "commit", "--quiet", "-m", "second commit")
        return self._git(self.installer_worktree, "rev-parse", "HEAD").strip()

    def request(self, **overrides: object) -> InstallRequest:
        fields: dict[str, object] = dict(
            installer_worktree=self.installer_worktree,
            installer_sha=self.installer_sha,
            source_worktree=self.source_worktree,
            source_sha=self.source_sha,
            renderer_root=self.renderer_root,
            build_gate=self.build_gate,
            promote=False,
        )
        fields.update(overrides)
        return InstallRequest(**fields)

    def staging_leftovers(self) -> list[Path]:
        return sorted(self.root.glob("echo-renderer-staging-*"))

    def published_source_roots(self) -> list[Path]:
        return sorted(p for p in self.renderer_root.iterdir() if p.is_dir())


class InstallationOrderTests(InstallFixture):
    def test_installs_in_the_required_order_and_publishes_a_verifiable_package(self):
        events: list[tuple[str, ...]] = []
        self.runner.events = events

        original_attest = ApprovedWorktree.attest.__func__
        def recording_attest(cls, root, approved_sha):
            events.append(("attest", str(root)))
            return original_attest(cls, root, approved_sha)

        self.enterContext(
            mock.patch.object(ApprovedWorktree, "attest", classmethod(recording_attest))
        )

        original_reattest = ApprovedWorktree.reattest
        def recording_reattest(worktree):
            events.append(("reattest", str(worktree.root)))
            return original_reattest(worktree)

        self.enterContext(
            mock.patch.object(ApprovedWorktree, "reattest", recording_reattest)
        )

        original_acquire = LeaseSet.acquire.__func__
        def recording_acquire(cls, *, lock_root, resources, wait=False):
            result = original_acquire(cls, lock_root=lock_root, resources=resources, wait=wait)
            events.append(("lease", tuple(sorted(str(r) for r in resources))))
            return result

        self.enterContext(
            mock.patch.object(LeaseSet, "acquire", classmethod(recording_acquire))
        )

        original_rename = os.rename
        def recording_rename(src, dst):
            events.append(("rename", str(src), str(dst)))
            return original_rename(src, dst)

        self.enterContext(
            mock.patch.object(store_module.os, "rename", recording_rename)
        )

        result = self.store.install(self.request())

        kinds = [event[0] for event in events]
        expected_kinds = (
            ["attest", "attest", "lease", "reattest", "reattest"]
            + ["runner"] * 7
            + ["reattest", "reattest", "rename"]
        )
        self.assertEqual(kinds, expected_kinds)

        # Attest, then re-attest (twice), always installer before source.
        self.assertEqual(events[0][1], str(self.installer_worktree))
        self.assertEqual(events[1][1], str(self.source_worktree))
        self.assertEqual(events[3][1], str(self.installer_worktree))
        self.assertEqual(events[4][1], str(self.source_worktree))
        self.assertEqual(events[12][1], str(self.installer_worktree))
        self.assertEqual(events[13][1], str(self.source_worktree))

        # Lease covers exactly the installer root, source root, and build output.
        self.assertEqual(
            events[2][1],
            tuple(
                sorted(
                    str(path.resolve())
                    for path in (
                        self.installer_worktree,
                        self.source_worktree,
                        self.source_worktree / ".build" / "cli",
                    )
                )
            ),
        )

        # Runner call order: gate, make, then the five release-CLI probes.
        runner_argument_lists = [call[0] for call in self.runner.calls]
        self.assertEqual(runner_argument_lists[0], (str(self.build_gate), "--wait"))
        self.assertEqual(
            runner_argument_lists[1], (MAKE, "-C", str(self.source_worktree), "echo-cli")
        )
        self.assertEqual(runner_argument_lists[2][1:], ("--version",))
        self.assertEqual(runner_argument_lists[3][1:], ("narrate", "--help"))
        self.assertEqual(runner_argument_lists[4][1:], ("verify-sidecar", "--help"))
        self.assertEqual(runner_argument_lists[5][0], "/usr/bin/lipo")
        self.assertEqual(runner_argument_lists[6][0], "/usr/bin/otool")

        # Rename is the final step, landing at <source SHA>/<manifest SHA>.
        verified = result.verified
        self.assertEqual(
            events[-1][2], str(self.renderer_root / self.source_sha / verified.manifest_sha)
        )

        self.assertIsInstance(result, InstallResult)
        self.assertFalse(result.selector_updated)
        self.assertEqual(verified.source_sha, self.source_sha)
        self.assertEqual(verified.manifest.echo_source_sha, self.source_sha)
        self.assertEqual(verified.manifest.installer_source_sha, self.installer_sha)
        self.assertEqual(
            verified.build_root, self.renderer_root / self.source_sha / verified.manifest_sha
        )
        self.assertTrue(verified.executable.is_file())
        self.assertEqual(stat.S_IMODE(verified.executable.stat().st_mode), 0o755)
        self.assertEqual(
            tuple(sorted(verified.manifest.capabilities)), tuple(sorted(REQUIRED_CAPABILITIES))
        )

        # The published package independently re-verifies through Task 4's
        # already-approved, read-only verification path.
        round_trip = RendererStore(self.renderer_root, runner=self.runner).verify(
            self.source_sha, verified.manifest_sha
        )
        self.assertEqual(round_trip, verified)


class InstallationIdempotenceTests(InstallFixture):
    def test_reinstalling_identical_inputs_is_idempotent(self):
        first = self.store.install(self.request())
        second = self.store.install(self.request())

        self.assertEqual(first.verified, second.verified)
        self.assertFalse(first.selector_updated)
        self.assertFalse(second.selector_updated)
        self.assertEqual(self.published_source_roots(), [self.renderer_root / self.source_sha])
        self.assertEqual(self.staging_leftovers(), [])

    def test_refuses_to_overwrite_a_differing_or_corrupt_destination(self):
        first = self.store.install(self.request())
        executable_path = first.verified.executable
        original_bytes = executable_path.read_bytes()
        executable_path.write_bytes(b"corrupted bytes that do not match the manifest\n")

        with self.assertRaises(ValueError):
            self.store.install(self.request())

        # The corrupted destination is left exactly as it was: install()
        # refuses to overwrite it rather than silently repairing it.
        self.assertEqual(
            executable_path.read_bytes(), b"corrupted bytes that do not match the manifest\n"
        )
        self.assertNotEqual(executable_path.read_bytes(), original_bytes)
        self.assertEqual(self.staging_leftovers(), [])

    def test_installs_a_second_manifest_for_the_same_source_side_by_side(self):
        first = self.store.install(self.request())

        second_installer_sha = self._recommit_installer("installer fixture v2\n")
        second = self.store.install(
            self.request(installer_sha=second_installer_sha)
        )

        self.assertEqual(first.verified.source_sha, second.verified.source_sha)
        self.assertNotEqual(first.verified.manifest_sha, second.verified.manifest_sha)
        source_dir = self.renderer_root / self.source_sha
        self.assertEqual(
            sorted(p.name for p in source_dir.iterdir()),
            sorted([first.verified.manifest_sha, second.verified.manifest_sha]),
        )
        # Neither installation moved the other.
        self.assertTrue((source_dir / first.verified.manifest_sha / "echo-cli").is_file())
        self.assertTrue((source_dir / second.verified.manifest_sha / "echo-cli").is_file())


class InstallationLayoutTests(InstallFixture):
    def test_executable_is_installed_with_mode_0755(self):
        result = self.store.install(self.request())

        mode = stat.S_IMODE(result.verified.executable.stat().st_mode)
        self.assertEqual(mode, 0o755)

    def test_published_directories_are_private_and_user_owned(self):
        result = self.store.install(self.request())

        source_dir = self.renderer_root / self.source_sha
        manifest_dir = result.verified.build_root
        for directory in (source_dir, manifest_dir):
            with self.subTest(directory=directory):
                info = directory.stat()
                self.assertEqual(stat.S_IMODE(info.st_mode), 0o700)
                self.assertEqual(info.st_uid, os.geteuid())


class InstallationCompletenessTests(InstallFixture):
    def test_a_file_dropped_from_staging_before_the_manifest_is_written_fails(self):
        self.runner.drop_staged_resource = "phonemes.txt"

        with self.assertRaises(ValueError):
            self.store.install(self.request())

        self.assertEqual(self.published_source_roots(), [])
        self.assertEqual(self.staging_leftovers(), [])


class InstallationFailureCleanupTests(InstallFixture):
    def test_a_failed_build_gate_leaves_no_staging_or_published_state(self):
        self.runner.gate_should_fail = True

        with self.assertRaises(ValueError):
            self.store.install(self.request())

        self.assertEqual(self.runner.make_calls, 0)
        self.assertEqual(self.published_source_roots(), [])
        self.assertEqual(self.staging_leftovers(), [])

    def test_a_failed_make_build_leaves_no_staging_or_published_state(self):
        self.runner.make_should_fail = True

        with self.assertRaises(ValueError):
            self.store.install(self.request())

        self.assertEqual(self.published_source_roots(), [])
        self.assertEqual(self.staging_leftovers(), [])

    def test_a_failed_probe_cleans_up_staging_without_publishing(self):
        broken_runner = InstallRunner(
            source_worktree=self.source_worktree,
            build_gate=self.build_gate,
            capabilities=REQUIRED_NARRATE_CAPABILITIES[:-1],
        )
        store = RendererStore(self.renderer_root, runner=broken_runner)

        with self.assertRaises(ValueError):
            store.install(self.request())

        self.assertEqual(self.published_source_roots(), [])
        self.assertEqual(self.staging_leftovers(), [])


class InstallationLeaseTests(InstallFixture):
    def test_contended_lease_exits_75_without_publishing(self):
        held = LeaseSet.acquire(
            lock_root=canonical_lease_root(), resources=(self.source_worktree,)
        )
        self.addCleanup(held.close)

        with self.assertRaises(SystemExit) as raised:
            self.store.install(self.request())

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        self.assertEqual(self.published_source_roots(), [])
        self.assertEqual(self.staging_leftovers(), [])


class InstallationRequestValidationTests(InstallFixture):
    def test_rejects_a_request_renderer_root_that_does_not_match_the_store(self):
        other_root = (self.root / "other-renderers").resolve()
        other_root.mkdir()

        with self.assertRaises(ValueError):
            self.store.install(self.request(renderer_root=other_root))

        self.assertEqual(self.published_source_roots(), [])


class RecordingPromoteStore(RendererStore):
    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.promote_calls: list[tuple[str, str]] = []

    def promote(self, source_sha: str, manifest_sha: str) -> Path:
        self.promote_calls.append((source_sha, manifest_sha))
        return self.renderer_root / source_sha / "approved-renderer.json"


class InstallationPromotionTests(InstallFixture):
    def test_promote_is_not_called_by_default(self):
        store = RecordingPromoteStore(self.renderer_root, runner=self.runner)

        result = store.install(self.request())

        self.assertEqual(store.promote_calls, [])
        self.assertFalse(result.selector_updated)

    def test_promote_is_called_after_publication_when_requested(self):
        store = RecordingPromoteStore(self.renderer_root, runner=self.runner)

        result = store.install(self.request(promote=True))

        self.assertEqual(
            store.promote_calls, [(self.source_sha, result.verified.manifest_sha)]
        )
        self.assertTrue(result.selector_updated)
        # The package must already be on disk when promote() runs.
        self.assertTrue(result.verified.build_root.is_dir())


if __name__ == "__main__":
    unittest.main()
